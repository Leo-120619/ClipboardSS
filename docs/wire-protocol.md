# ClipboardSS Wire Protocol (v2)

This is the LAN protocol spoken by the three ClipboardSS apps: macOS (Swift,
`Sources/ClipboardCore` + `Sources/ClipboardSS`), the Flutter companion (Android, iOS,
Windows desktop; `clipboard_companion/lib/core`) and Windows (C#,
`ClipboardSS.Windows/src/ClipboardSS.Core` + `ClipboardSS.WinApp`). Protocol version 2 is
not compatible with version 1: a v2 device refuses v1 envelopes (`426`) and v1 pairing.

Where the three implementations differ, this document says so. The pinned test vectors are
asserted byte-for-byte by all three test suites.

Contents: [Discovery](#discovery-mdns--bonjour) · [Transport and request limits](#http-transport-and-request-limits) ·
[Identity probe](#identity-probe) · [Envelope v2](#envelope-v2) ·
[Freshness and replay](#freshness-and-replay-protection) · [Liveness ping](#liveness-ping) ·
[Pairing v2](#pairing-protocol-v2-commit-reveal--on-screen-number) · [Clip sync](#clip-synchronization) ·
[File transfer](#file-transfer-protocol) · [Hash parity](#hash-parity-contract) ·
[Security model](#security-model)

## Discovery (mDNS / Bonjour)

- **Type**: `_clipboardss._tcp`
- **Port**: `51888`
- **TXT record**:
  - `deviceId`: the device's UUID.
  - `deviceName`: human-readable name, ASCII only (curly quotes are straightened and other
    non-ASCII is dropped, because some Android resolvers fail on multi-byte TXT values).
  - `v`: `"2"` (protocol version). Browsers still list peers advertising an older `v`, marked
    "needs update", and never send to them.
- Browsers drop a peer when it says goodbye (TTL 0) or its record TTL runs out unrefreshed.

Devices may also find peers by sweeping local subnet hosts with `GET /v1/id`.

**mDNS and `/v1/id` only nominate.** Neither is authenticated: anyone on the LAN can
advertise, or answer with, a paired device's id. They nominate candidate hosts (and find
unpaired devices to pair with). A paired device is marked online, and its stored host
changes, only after a valid pong to an authenticated ping (see [Liveness ping](#liveness-ping)).
Clips and files for a paired device always go to its stored host, never to an address mDNS
or `/v1/id` claimed.

## HTTP transport and request limits

All servers listen on TCP `51888` on all IPv4 interfaces. Each connection carries **one**
HTTP/1.1 request; the server answers with `Connection: close` and closes. Transport is plain
HTTP: confidentiality and authenticity of content come from the application-level
ChaCha20-Poly1305 envelope and chunk encryption. Request and response framing (method, path,
headers, status codes, and the JSON of the unencrypted endpoints) is plaintext.

Device ids are not spelled the same on the wire: the Mac's JSON encoder writes UUIDs in
uppercase (`/v1/id`, envelope `sourceDeviceId`, pairing `deviceId`), Dart and C# write
lowercase. Every receiver parses ids case-insensitively. Anything **derived** from an id
(associated data, `proof`, `fileKey` info) uses the lowercase canonical form.

Server limits:

| Limit | Mac (`ClipServer`) | Windows (`TcpClipServer`) | Flutter (shelf) |
|-------|--------------------|---------------------------|-----------------|
| Header block | 16 KB → `431` | 16 KB → `431` | dart:io `HttpServer` defaults (no 431 of its own) |
| Body | 20 MB → `413` | 20 MB → `413` | 20 MB, `Content-Length` checked up front and a running cap while reading → `413` |
| Request deadline | 15 s from accept to a complete request, else the connection is closed | 15 s, same rule | none |
| Concurrent connections | not capped | 64; excess connections are closed at accept | not capped |

The 15 s deadline covers only **receiving** the request. Handling time is not limited, so
`/v1/pair/confirm`, which the target may hold for up to 60 s, still gets its answer, and a
`/v1/file/finish` that hashes a large file is not cut short.

Clients time out a request after **10 s**, except `/v1/pair/confirm` (**75 s**) and
`/v1/file/finish` (size-scaled, see [finish timeout](#endpoints)).

## Identity probe

`GET /v1/id` → `200`

```json
{
  "deviceId": "<uuid>",
  "deviceName": "<string>",
  "v": 2
}
```

Unauthenticated; see the nomination rule above.

## Envelope v2

Every authenticated request (and the pong response) carries this JSON body:

```json
{
  "v": 2,
  "sourceDeviceId": "<uuid>",      // the sender
  "nonce": "<base64>",             // 12 random bytes, fresh per envelope
  "ciphertext": "<base64>"         // ChaCha20-Poly1305 ciphertext || 16-byte tag
}
```

The key is the device `pairKey` from pairing. The **associated data** binds sender,
recipient and purpose:

```
aad = UTF-8("ClipboardSS/2|" + purpose + "|" + lowercase(sourceDeviceId) + "|" + lowercase(recipientDeviceId))
```

- `recipientDeviceId` is the device the envelope is addressed to. A receiver always uses
  **its own** id as the recipient, so an envelope reflected back to its sender, or delivered
  to another device, fails the tag.
- `purpose` is one of:

  | purpose       | endpoint                   |
  |---------------|----------------------------|
  | `clip`        | `POST /v1/clip`            |
  | `file-offer`  | `POST /v1/file/offer`      |
  | `file-finish` | `POST /v1/file/finish`     |
  | `file-cancel` | `POST /v1/file/cancel`     |
  | `ping`        | `POST /v1/ping` (request)  |
  | `pong`        | `POST /v1/ping` (response) |

  An envelope sealed for one endpoint fails the tag on any other (a captured offer cannot
  cancel or finish a transfer).
- Receivers check `v` before anything else. `v != 2` gets
  `426 {"status":"upgradeRequired","minVersion":2}` on every envelope endpoint. A sender
  that receives `426`, or whose peer advertises an older `v`, shows "update the other
  device", never "unauthorized" or a re-pair prompt.

### Envelope v2 Test Vector (pinned, cross-platform)

Swift, Dart, and .NET MUST reproduce this byte-for-byte.

- `pairKey` = 32 bytes `000102...1e1f` (`00`..`1f`)
- `nonce` = `000000000000000000000001`
- `sourceDeviceId` = `11111111-1111-1111-1111-111111111111`
- `recipientDeviceId` = `22222222-2222-2222-2222-222222222222`
- `purpose` = `clip`
- `aad` = `ClipboardSS/2|clip|11111111-1111-1111-1111-111111111111|22222222-2222-2222-2222-222222222222`
- plaintext = UTF-8 `{"a":1}`
- → `ciphertext || tag` (hex) = `127e1dfb0b3bc54f07dfeda46cd545278be6adeef430c1`

## Freshness and replay protection

Every inner payload (clip, file-offer, file-finish, file-cancel, ping, pong) carries
`"sentAt"`, the sender's clock at seal time. It is **inside** the ciphertext, so it is
authenticated. Every platform writes it in whole-second UTC, `yyyy-MM-ddTHH:mm:ssZ`
(e.g. `2026-11-10T12:00:00Z`); the seal helpers stamp it automatically.

Each receiver process keeps **one** replay guard, shared by every envelope endpoint
(clip, file offer/finish/cancel, ping). On every envelope receive path the order is:

1. `v` check (`426`), then pairing / paused checks (`401`; ping skips the pause check).
2. AEAD open. A failed open is rejected and never touches the guard.
3. Guard check, in this order:
   - `|now − sentAt| > 300 s` → `400 {"status":"stale"}`. A missing or unparsable `sentAt`
     is stale. Stale envelopes are not remembered.
   - `(lowercase sourceDeviceId, nonce bytes)` already accepted in the last **600 s** →
     `409 {"status":"replayed"}`. The nonce is compared by its decoded bytes, not its
     base64 spelling.
   - otherwise the pair is remembered and the request continues.
4. Only then any side effect (pasteboard, clip store, transfer session create/teardown, pong).

Retention (600 s) covers the whole acceptance window: an envelope accepted at receiver time
`t` carries `sentAt ≤ t + 300`, so it is stale from `t + 600` on. File chunks are not
enveloped and not guarded; they are bound to a session that only a fresh offer can create.

A sender that receives `400 {"status":"stale"}` shows "Clock out of sync with <device>."
(never "unauthorized" or a re-pair prompt). Clock skew of up to 5 minutes still syncs.

**Freshness test vector** (all three suites assert it):

- `sentAt` for the instant `1794312000` (Unix seconds), sealed with a 456 ms fraction,
  is written as `2026-11-10T12:00:00Z` and parses back to `1794312000`.
- Receiver clock `now`: `sentAt = now − 240 s` and `now + 240 s` → ok;
  `now − 300 s` → ok (inclusive); `now − 301 s`, `now ± 1200 s` → stale.
- The same `(sourceDeviceId, nonce)` again at `now + 599 s` → replayed; at `now + 601 s`
  the entry has expired.

## Liveness ping

- **Caller → device**: `POST /v1/ping`, body a v2 envelope with purpose `ping`, sealed to
  the device being checked. Inner JSON: `{"sentAt":"2026-11-10T12:00:00Z"}`.
- **Device → caller**: `200`, body a v2 envelope with purpose `pong`, source = the device,
  recipient = the caller. Inner JSON, where `pingNonce` is the ping envelope's `nonce` as
  received:
  ```json
  {
    "pingNonce": "<base64>",
    "sentAt": "2026-11-10T12:00:00Z"
  }
  ```

Responder order: undecodable body `400`; `v` check `426`; sender not paired `401`; AEAD
open failure `401`; replay guard (`400 {"status":"stale"}` / `409 {"status":"replayed"}`,
the shared guard); then the pong. The responder's local **pause** switch is not checked:
liveness reports reachability, and a paused device still refuses content with `401`.
(The `401` body is empty on the Mac and `{"status":"unauthorized"}` on Dart and C#.)

Caller validation: the ping counts as **alive** only if all of these hold:

1. status `200`;
2. the body is a v2 envelope whose `sourceDeviceId` is the device that was pinged;
3. it opens with purpose `pong`, recipient = the caller's own id, under that device's `pairKey`;
4. `|now − sentAt| ≤ 300 s` (the replay guard's freshness window);
5. `pingNonce` decodes to the same 12 bytes as this ping's nonce. A pong is single-use: a
   captured pong cannot answer a later ping.

Outcomes:

- **alive** → the device is online at the pinged host; if that host differs from the stored
  one, the stored host is updated; the device leaves the outdated set (a pong proves v2).
  While it keeps ponging, an mDNS advertisement of an older `v` for its id is ignored (that
  would otherwise let anyone on the LAN block traffic to a live device).
- `426`, or `404` (a v1 server has no `/v1/ping` route) → the device is marked outdated
  ("update the other device"); not online, host unchanged. This lets a v1 peer seen only at
  its stored host show "update the other device" from the liveness timer.
- `400 {"status":"stale"}` → **clock skew**: the device shows "Clock out of sync", and
  reconnect / file-send errors read "Clock out of sync with <device>." (the same text as a
  stale clip). This answer is unauthenticated, so the device is not online and its host is
  unchanged; a later valid pong clears it.
- anything else (timeout, `401`, other `400`, `409`, an invalid pong) → no evidence: not
  online at that host, host unchanged.

**Liveness rule.** A paired device is online only after a valid pong. Callers try the
device's mDNS address(es) first, then its stored host. Reconnecting may also sweep the subnet
with `GET /v1/id`; hosts claiming the device's id are pinged like any other candidate. A v1
peer cannot answer a ping (it answers `404`, treated as outdated above), so a sweep result advertising `v < 2` (with no valid pong
anywhere) marks the device outdated; a later valid pong clears that.

**Ping/pong test vector** (all three suites assert it): the Envelope v2 vector above with
`purpose` = `ping` gives `ciphertext || tag` = `127e1dfb0b3bc52649f874034b63d5fa53c0a4886a60a1`,
and with `purpose` = `pong` gives `127e1dfb0b3bc535d219b680a4ddb08aac15ee49a426c4`.

## Pairing protocol v2 (commit-reveal + on-screen number)

Pairing endpoints are plaintext JSON (no envelope). The **target** must be hosting: it shows a
6-digit code valid for **180 s**. On the **initiator** the user picks **one** device and
enters the code; then both screens show a 6-digit `confirmCode` with both device names, and
the user confirms on both devices that the numbers match.

The initiator commits to its key before it sees the target's, so neither side can grind keys
toward a chosen number. A device that answers `/v1/pair/start` without knowing the code learns
nothing it can test offline before both users have confirmed. Neither side stores a key until
both users have confirmed.

1. **Initiator → target**: `POST /v1/pair/start`
   ```json
   {
     "deviceId": "<uuid>",
     "deviceName": "<string>",
     "commitment": "<base64>" // SHA256(initiatorPublicKey || salt), salt = 16 random bytes
   }
   ```
   → `200 {"deviceId": "<uuid>", "deviceName": "<string>", "ephemeralPublicKey": "<base64>"}`
   (the target's X25519 public key).
   → `403` when no code is active, the commitment is not 32 bytes, or a field is missing
   (Dart answers `500` for other unexpected errors).
   **One target key per code**: any second start for the same code (same deviceId or not)
   ends the code with `403`, so a code holder cannot re-roll the comparison number.
2. **Initiator → target**: `POST /v1/pair/reveal`
   `{"deviceId": "<uuid>", "ephemeralPublicKey": "<base64>", "salt": "<base64>"}`
   → `200 {"status":"ok"}`
   → `401` no active code, or no matching pending initiator (wrong deviceId, or already
   revealed); the latter also ends the code.
   → `400` the salt is not 16 bytes, or the key and salt do not open the commitment
   (constant-time check); this ends the code.
3. **Both compute**, with `sharedSecret` = X25519(localPrivate, remotePublic) and
   `transcript` = ASCII code `||` initiatorPublicKey `||` targetPublicKey (raw 32-byte keys):
   - `pairKey` (32 bytes) = HKDF-SHA256(secret=sharedSecret, salt="ClipboardSS_PairKey", info=transcript)
   - `confirmCode` = HKDF-SHA256(secret=sharedSecret, salt="ClipboardSS_ConfirmCode", info=transcript, 4 bytes),
     read as a big-endian UInt32, mod 1 000 000, zero-padded to 6 digits.
4. **Both screens** show `confirmCode` and both device names with Confirm / Cancel. Confirm on
   the target is local. Confirm on the initiator sends `POST /v1/pair/confirm`
   `{"deviceId": "<uuid>", "proof": "<base64>"}` with
   `proof` = HMAC-SHA256(key=pairKey, message="confirm" + initiatorId + targetId) (lowercase UUIDs).
   The target checks the proof (constant-time), then, unless its user already confirmed,
   **holds the request up to 60 s** until its user decides:
   - `200 {"status":"ok"}`: both users confirmed. The target has stored the pairing; the
     initiator stores it on this answer.
   - `401`: no active code, wrong deviceId or proof, or the target's user cancelled.
   - `408 {"status":"timeout"}`: the target's user did not confirm within 60 s.
   - `409 {"status":"alreadyPaired"}`: the target already has this deviceId paired
     (checked after the proof).

   **Cancel on the initiator** (before or after its own Confirm) sends this request with an
   invalid proof (32 zero bytes). The target ends its code and comparison, and answers a held
   confirm from that deviceId with `401`. The initiator stores nothing, whatever it hears.

Target rules: every confirm spends the code. Any failure (second start, bad reveal or
commitment, bad proof, cancel on the target, 60 s timeout) ends the code and clears pending
state, as do stop, expiry and starting a new code. Codes, numbers and keys are never logged.

### Pairing v2 Test Vector (pinned, cross-platform)

Swift, Dart, and .NET MUST reproduce this byte-for-byte. Keys are the RFC 7748 §6.1 pair.

- initiator private key = `77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a`
  → public `8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a`
- target private key = `5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb`
  → public `de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f`
- `salt` = 16 bytes `000102...0e0f` (`00`..`0f`); code = `123456`
- → `commitment` (hex) = `c288f1b99596594082bc7d2c3684e2baef0516454e44b3cd6d7bcbd8845f4c55`
- → `pairKey` (hex) = `8088860b8ecd246dbb52966bba419592f44ab2da96dec0d03725257384cdb83f`
- → `confirmCode` = `885454`
- → `proof` for initiatorId `550e8400-e29b-41d4-a716-446655440000`, targetId
  `4d967c79-47dc-4e1f-a3bd-d3160b082da7` (hex) =
  `b4bb2c3b5b26e686aba290b1e6469b756684cb6f131b355f106905140204c23b`

## Clip synchronization

`POST /v1/clip`, `Content-Type: application/json`, body a v2 envelope with purpose `clip`.

Decrypted inner JSON:

```json
{
  "id": "<uuid>",
  "type": "text|image",
  "createdAt": "2023-10-24T12:00:00Z", // ISO-8601
  "text": "...",                       // if type=text
  "imageBase64": "...",                // if type=image
  "imageExtension": "png",             // if type=image
  "previewText": "...",
  "contentHash": "<sha256 hex>",
  "sourceDeviceName": "...",
  "sentAt": "2026-11-10T12:00:00Z"     // see Freshness and replay protection
}
```

Responses:

- `200`: accepted. Mac and Windows answer `{"status":"ok"}` or `{"status":"duplicate"}`
  (already in history); Flutter answers plain `OK`.
- `401`: sender not paired, or paused on this device.
- `426 {"status":"upgradeRequired","minVersion":2}`.
- `400 {"status":"stale"}` · `409 {"status":"replayed"}`.
- `400`: anything else, **including an AEAD failure** on this endpoint, and (Flutter) an
  invalid image payload.
- `413`: body over 20 MB, which bounds inline images.

## File Transfer Protocol

QuickDrop-style explicit file send between paired devices. Large files cannot travel as
inline base64 in `/v1/clip` (20 MB cap, several in-memory copies). Instead files are split
into **4 MiB plaintext chunks**, each sent as one HTTP request with a **binary body**
(`application/octet-stream`, never base64). Sender and receiver stream to and from disk and
never hold the whole file.

Chunk-per-request fits the servers as built: all three buffer the whole request body and
close the connection after one response, so there is no streaming or keep-alive.

### Crypto

Control messages (offer / finish / cancel) are v2 envelopes under the device `pairKey`, with
purposes `file-offer`, `file-finish` and `file-cancel`.

Chunks are **not** enveloped. They use a per-transfer key with deterministic nonces, so each
chunk is bound to its index (a chunk replayed at the wrong offset fails the tag):

```
fileKey    = HKDF-SHA256(secret = pairKey,
                         salt   = "ClipboardSS_FileKey",   // ASCII, no NUL
                         info   = ASCII lowercase transferId,
                         L      = 32)
chunkNonce = 0x00 0x00 0x00 0x00 || uint64_big_endian(chunkIndex)   // 12 bytes
chunkBody  = ChaCha20-Poly1305(key = fileKey, nonce = chunkNonce, plaintext = slice)
           = ciphertext || 16-byte tag
```

`transferId` MUST be a fresh random UUID per transfer (nonce-reuse safety). A receiver
rejects a reused **active** `transferId` with `409`.

### fileHash

`ContentHasher`'s `"file"` namespace, computed by **streaming** the file:

```
fileHash = SHA256("file" + 0x00 + fileBytes)   // lowercase hex
```

### Endpoints

All on port `51888`. Response bodies are JSON `{"status": "..."}` unless noted.

1. **`POST /v1/file/offer`**, envelope purpose `file-offer`, inner JSON:
   ```json
   {
     "transferId": "<lowercase uuid>",
     "fileName": "movie.mp4",
     "fileSize": 157286400,
     "mimeType": "video/mp4",
     "fileHash": "<sha256 hex, 'file' namespace>",
     "chunkSize": 4194304,
     "chunkCount": 38,
     "createdAt": "2026-07-10T12:00:00Z",
     "sourceDeviceName": "Leo's Mac",
     "sentAt": "2026-07-10T12:00:00Z"
   }
   ```
   Receiver checks, after the envelope checks (`426`; `401` unpaired, paused or AEAD
   failure; `400 stale` / `409 replayed`):
   - `400 {"status":"invalidId"}`: `transferId` does not match `^[a-z0-9-]{1,64}$`.
   - `400 {"status":"invalidOffer"}`: the offer math fails. It MUST satisfy
     `0 < chunkSize <= 4 MiB`, `fileSize >= 0` and
     `chunkCount == ceil(fileSize / chunkSize)` (zero for an empty file).
   - `409 {"status":"duplicate"}`: the `transferId` is already active. (Windows checks this
     before `invalidOffer`; Swift and Dart after.)
   - `429 {"status":"tooManyTransfers"}`: the sending device already holds **8** active
     sessions (counted per authenticated `sourceDeviceId`; Dart also counts offers still
     being set up).
   - `400 {"status":"tooLarge"}`: quota. The offer is refused when
     `fileSize > freeSpace − committed − 500 MB` (500 MB = 524,288,000 bytes), where
     `freeSpace` is the free space on the receiver's transfers volume and `committed` is the
     bytes active sessions still owe but have not yet written:
     Σ `(fileSize − bytes written)` on Swift and Dart (Dart also adds the full size of other
     offers still being set up). **Windows preallocates** each `.part` to `fileSize` with
     `SetLength`, so that space is already gone from `freeSpace` and `committed` is 0 there.
     When free space is already under the 500 MB floor, even a zero-byte offer is refused.
     When free space cannot be determined, transfers are not blocked.
   - `400 {"status":"error"}`: creating the temp file failed.
   - `403 {"status":"declined"}`: reserved for a future accept prompt; v2 auto-accepts.
   - `200 {"status":"ready"}`.

   No transfer state or `.part` file exists before every check above has passed.

2. **`POST /v1/file/chunk`**: headers `X-Transfer-Id`, `X-Chunk-Index`; body = raw
   `ciphertext || tag` (`application/octet-stream`). Codecs lowercase header keys, so
   servers read `x-transfer-id` / `x-chunk-index`.
   - `200 {"status":"ok","received":<n>}` (n = distinct chunks stored)
   - `404 {"status":"unknown"}`: unknown or expired transferId.
   - `410 {"status":"cancelled"}`: the transfer was cancelled.
   - `400 {"status":"badIndex"}`: index outside `0..<chunkCount` (Windows answers a plain
     `400` when a header is missing or not an integer).
   - `400 {"status":"authFailed"}` (Windows: `"decryptFailed"`): the body fails the tag.
   - `400 {"status":"badSize"}`: plaintext size is not `chunkSize` (or the remainder, for
     the last chunk).
   - `400 {"status":"writeFailed"}`: the write to the `.part` failed.

   **Chunk-error semantics.** Chunks are not enveloped, so anyone who sees the plaintext
   `X-Transfer-Id` can post one. A rejected chunk MUST leave the session intact (no teardown,
   no activity refresh), so the genuine sender's chunks and finish still succeed. A repeated
   index is an idempotent `200` only after its body authenticates. An index counts as
   received only after its bytes are written, so a failed write may be retried.

3. **`POST /v1/file/finish`**, envelope purpose `file-finish`, inner
   `{"transferId": "...", "sentAt": "..."}`. The receiver checks every chunk is present,
   streams the `.part` through `fileHash` and, on a match, moves it to the destination.
   - `200 {"status":"complete"}` (Mac and Dart add `"fileName"`).
   - `409 {"status":"incomplete"}`: chunks missing; the session stays.
   - `422 {"status":"hashMismatch"}` · `422 {"status":"error"}` (hashing or move failed):
     both destroy the session and its temp file.
   - `401`: unpaired, paused or AEAD failure.
   - `404 {"status":"unknown"}`: unknown transferId, **or a session owned by a different
     device** (the envelope's `sourceDeviceId` must equal the offer's).
   - Dart only, which hashes without holding a lock: `409 {"status":"finishing"}` for a second
     finish of the same transfer, and `410 {"status":"cancelled"}` for a finish whose session
     was cancelled mid-hash. Swift and C# hash under the transfer lock, so a second finish
     finds the transfer gone (`404`).

   **Finish timeout.** The receiver answers only after hashing the whole file, so senders wait
   `min(600, max(30, ceil(fileSize / 20 MiB)))` seconds for this one request (4 GiB → 205 s).
   A finish that times out is reported **unconfirmed**, not failed, and the sender sends no
   cancel: the receiver may still be saving the file. While a finish is hashing, idle GC
   keeps the session alive.

4. **`POST /v1/file/cancel`**, envelope purpose `file-cancel`, inner
   `{"transferId": "...", "sentAt": "..."}`. Idempotent `200 {"status":"cancelled"}`,
   including for an unknown transferId. Also `400 stale` / `409 replayed`; `401` from a
   paused device; `404 {"status":"unknown"}` when the session belongs to a different device
   (the session is left intact). For an unpaired sender or an AEAD failure, **Windows answers
   `401`** while Swift and Dart answer `200`; cancel is best-effort and senders ignore the
   reply. Cancelled ids are remembered for **600 s** (chunks for them get `410`), then pruned.

On the file endpoints Windows answers the envelope-level `401` (and an undecodable body's
`400`) as plain text; Swift and Dart use JSON (`{"status":"unpaired"}`, `{"status":"paused"}`).

### Semantics

- **Auto-accept** from paired devices (the `403 declined` path is reserved).
- **Restart-only** on failure. Deterministic nonces would let a future version resume via a
  chunk bitmap with no wire-format change.
- The receiver holds sessions **in memory**; chunk plaintext is written to a `.part` temp
  file at `chunkIndex * chunkSize`; sessions are GC'd after **60 s** idle.
- Every path that ends a session (cancel, hash mismatch, finalize failure, idle GC, failed
  offer setup) closes the file handle and deletes the `.part`.
- The sender streams the file in 4 MiB slices (two passes: streaming hash, then
  offer → chunks → finish) and aborts on any non-200, best-effort sending
  `/v1/file/cancel` (except after a finish timeout, see above).

### File Transfer Test Vectors (pinned, cross-platform)

Swift, Dart, and .NET MUST reproduce these byte-for-byte.

- **fileHash** of `[0x01, 0x02, 0x03]`:
  `53d35d037113cb046848c134d774023f716d41879185bb35b942a0472bcd70fe`
- **fileKey** derivation inputs:
  - `pairKey` = 32 bytes `000102...1e1f` (`00`..`1f`)
  - `transferId` = `6f9619ff-8b86-d011-b42d-00c04fc964ff`
  - → `fileKey` = `2b3f780b885ee8149fe062a00b2bb4ecc9b4326c058ad858b23009f3397a4554`
- **chunkNonce**: index 0 → `000000000000000000000000`, index 1 → `000000000000000000000001`
- **chunk body** (`ciphertext || tag`, hex) for plaintext `[0x01, 0x02, 0x03]` under the
  `fileKey` above:
  - index 0 → `878b3fd3c6494ba0be8976ec7543362243af08`
  - index 1 → `fc5bf0de6da51d44d7e16d35ec05ed598dd1cf`

  (Same plaintext, different index ⇒ different ciphertext: this is the nonce binding.)

## Hash Parity Contract

`ContentHasher` generates hashes using SHA-256 over a namespaced payload.

Algorithm: `SHA256(namespace + 0x00 + data)`
- For text: `namespace` = "text"
- For image: `namespace` = "image"
- For file: `namespace` = "file"

**Test Vectors**:
1. Text: "Hello, world!"
   Hash: `f2860ecbb844a4c152aed2007055a3d41911dcb0fb7a64b996525d5b62a722e1`

2. Image: `[1, 2, 3]` (Bytes 0x01, 0x02, 0x03)
   Hash: `1b91e2105a1a014f55e1038235f53eae70458235d3f37da8672b563a21c04929`

3. File: `[1, 2, 3]` (Bytes 0x01, 0x02, 0x03)
   Hash: `53d35d037113cb046848c134d774023f716d41879185bb35b942a0472bcd70fe`

## Security model

ClipboardSS assumes a home or office LAN. It is not designed to run over the internet.

**Protected:**

- **Clip and file contents** are encrypted and authenticated end to end between two paired
  devices (ChaCha20-Poly1305 under a per-pair key; per-transfer keys for file chunks).
- **Sender, recipient and purpose**: the envelope's associated data binds all three, so an
  envelope cannot be reflected, redirected or reused on another endpoint.
- **Replay**: `sentAt` (±300 s) plus the 600 s replay set refuse a captured envelope.
- **Pairing**: commit-reveal plus a 6-digit number compared on both screens defeats a
  man-in-the-middle unless both users confirm numbers that do not match. A code hands out
  one target key, so a code holder cannot re-roll the number.
- **Liveness and routing**: a device is online, and its host changes, only after a valid
  pong under its pair key.

**Not protected:**

- **Network reach.** Servers listen on all IPv4 interfaces on port 51888. Any host that can
  reach the port can connect; only pairing keys gate content.
- **Plaintext framing and metadata.** HTTP framing is unencrypted. An observer on the LAN
  sees device ids and names (mDNS, `/v1/id`, envelope `sourceDeviceId`), endpoints and status
  codes, transfer ids (`X-Transfer-Id`), chunk indices and sizes, envelope sizes (so roughly
  how large a clip or file is), timing, and the full JSON of the pairing endpoints (device
  ids and names, public keys, commitment, salt, proof; never the code).
- **History at rest is not encrypted.** The Mac keeps clip history in `clips.json` with image
  files beside it; Windows keeps a `clips.json` store the same way; the Flutter app keeps clip
  history in SharedPreferences. Anyone with access to the user account can read them. Pair
  keys are stored separately: macOS Keychain; Flutter secure storage (Android Keystore, iOS
  Keychain, and on Windows AES-GCM files keyed from Credential Manager); Windows DPAPI.
- **Sensitive clipboard items.** Only the Mac skips items the source app marks concealed,
  transient or auto-generated (`org.nspasteboard.ConcealedType` and related types, as password
  managers set them). Flutter and Windows capture and sync whatever is on the clipboard.

**Accepted LAN denial-of-service vectors** (an attacker on the LAN can disrupt, not read):

- A bogus `/v1/pair/start`, `/v1/pair/reveal` or `/v1/pair/confirm` ends the code a device
  is hosting; the user generates a new one.
- mDNS and `/v1/id` can nominate a fake host for a paired device's id, costing a failed
  ping. They cannot route clips or files there or mark a device online.
- Anyone who sees an `X-Transfer-Id` can post junk chunks. They are rejected without
  harming the session, but each costs the receiver an AEAD check.
- Connection floods: Windows closes connections beyond 64; the Mac and Flutter servers have
  no connection cap, and Flutter has no request deadline.
