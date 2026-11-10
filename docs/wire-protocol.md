# Cross-Device Clipboard Sync Wire Protocol

## mDNS / Bonjour
- **Type**: `_clipboardss._tcp`
- **Port**: `51888`
- **TXT Record**:
  - `deviceId`: Lowercase canonical UUID string representing the device's unique identity.
  - `deviceName`: Human-readable string.
  - `v`: "2" (protocol version). Browsers still list peers advertising an older `v`, marked
    "needs update", and never send to them.
- Browsers drop a peer when it says goodbye (TTL 0) or its record TTL runs out unrefreshed.

## HTTP Transport
Transport is plain HTTP (unencrypted at the transport layer). Confidentiality and authenticity are provided by the application-level encryption (ChaCha20-Poly1305).

All clip servers listen on TCP port `51888`. Devices may discover peers through mDNS or by probing local subnet hosts with `GET /v1/id`.

Neither mDNS nor `/v1/id` is authenticated: anyone on the LAN can advertise or answer with a
paired device's public id. They only **nominate candidate hosts** (and find unpaired devices to
pair with). A paired device is marked online, and its stored host is changed, only after a
valid pong to an authenticated ping (see [Liveness Ping](#liveness-ping)). Clips and files for a
paired device always go to its stored host, never to an address mDNS or `/v1/id` claimed.

## Identity Probe

- **Requester -> Candidate peer**:
  `GET /v1/id`

- **Candidate peer -> Requester**:
  ```json
  {
    "deviceId": "<uuid>",
    "deviceName": "<string>",
    "v": 2
  }
  ```

## Pairing Protocol (v2: commit-reveal + on-screen number)

Pairing endpoints are plaintext JSON (no envelope). The target must be in pairing mode: it
shows a short-lived 6-digit code (180 s). The user picks **one** device on the initiator,
enters the code there, and then both screens show a 6-digit `confirmCode` with both device
names. The user confirms on both devices that the numbers match. The initiator commits to its
key before seeing the target's, so neither side can grind keys toward a chosen number, and a
device that answers `/v1/pair/start` without knowing the code learns nothing it can test offline
until both users have confirmed.

1. **Initiator -> Target**: `POST /v1/pair/start`
   ```json
   {
     "deviceId": "<lowercase uuid>",
     "deviceName": "<string>",
     "commitment": "<base64>" // SHA256(initiatorPublicKey || salt), salt = 16 random bytes
   }
   ```
2. **Target -> Initiator**: `200`
   `{"deviceId": "<lowercase uuid>", "deviceName": "<string>", "ephemeralPublicKey": "<base64>"}`
   (X25519 public key). `403` when no code is active, another initiator is pending, or the
   commitment is not 32 bytes. The same deviceId may restart until it has revealed.
3. **Initiator -> Target**: `POST /v1/pair/reveal`
   `{"deviceId": "<lowercase uuid>", "ephemeralPublicKey": "<base64>", "salt": "<base64>"}`
   → `200 {"status":"ok"}` · `401` no active code or no matching pending initiator ·
   `400` the key and salt do not open the commitment (constant-time check).
4. **Both compute**, with `sharedSecret` = X25519(localPrivate, remotePublic) and
   `transcript` = ASCII code `||` initiatorPublicKey `||` targetPublicKey (raw 32-byte keys):
   - `pairKey` (32 bytes) = HKDF-SHA256(secret=sharedSecret, salt="ClipboardSS_PairKey", info=transcript)
   - `confirmCode` = HKDF-SHA256(secret=sharedSecret, salt="ClipboardSS_ConfirmCode", info=transcript, 4 bytes),
     read as a big-endian UInt32, mod 1 000 000, zero-padded to 6 digits.
5. **Both screens** show `confirmCode` and both device names with Confirm / Cancel. Confirm on
   the target is local. Confirm on the initiator sends `POST /v1/pair/confirm`
   `{"deviceId": "<lowercase uuid>", "proof": "<base64>"}` with
   `proof` = HMAC-SHA256(key=pairKey, message="confirm" + initiatorId + targetId) (lowercase UUIDs).
   The target checks the proof (constant-time), then **holds the request up to 60 s** until its
   own user decides:
   - `200 {"status":"ok"}`: both users confirmed; the target has stored the pairing, and the
     initiator stores it on this answer. Neither side stores a key earlier.
   - `401`: no active code, wrong deviceId or proof, or the target's user cancelled.
   - `408 {"status":"timeout"}`: the target's user did not confirm within 60 s.
   - `409 {"status":"alreadyPaired"}`: the target already has this deviceId paired.
   Clients use a 75 s timeout for this request (10 s for the others). The servers' 15 s
   request deadline covers only receiving the request, not this hold.

Target rules: every confirm spends the code; any failure (bad reveal or commitment, bad proof,
cancel on the target, 60 s timeout) ends the code and clears pending state, as do stop, expiry
and starting a new code. Codes, numbers and keys are never logged.

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

## Clip Synchronization Protocol

- **Initiator -> Target**:
  `POST /v1/clip`
  Content-Type: `application/json`

  **Envelope Payload** (v2):
  ```json
  {
    "v": 2,
    "sourceDeviceId": "<lowercase uuid>",
    "nonce": "<base64>", // 12-byte ChaCha20-Poly1305 nonce
    "ciphertext": "<base64>" // Encrypted inner JSON + 16-byte Poly1305 auth tag
  }
  ```

  **Decrypted Inner JSON**:
  ```json
  {
    "id": "<lowercase uuid>",
    "type": "text|image",
    "createdAt": "2023-10-24T12:00:00Z", // ISO-8601
    "text": "...", // Optional (if type=text)
    "imageBase64": "...", // Optional (if type=image)
    "imageExtension": "png", // Optional (if type=image)
    "previewText": "...",
    "contentHash": "<sha256 hex>",
    "sourceDeviceName": "...",
    "sentAt": "2026-11-10T12:00:00Z" // set at seal time; see Freshness and replay protection
  }
  ```

  Responses: `200 {"status":"ok"|"duplicate"}` · `401` unpaired/paused · `426` upgradeRequired ·
  `400 {"status":"stale"}` · `409 {"status":"replayed"}` · `400` otherwise.

## Envelope v2 (all envelope-carrying endpoints)

Every envelope is ChaCha20-Poly1305 under the device `pairKey` with **associated data**
binding sender, recipient and purpose:

```
aad = UTF-8("ClipboardSS/2|" + purpose + "|" + lowercase(sourceDeviceId) + "|" + lowercase(recipientDeviceId))
```

- `sourceDeviceId` is the envelope field (the sender); `recipientDeviceId` is the device the
  envelope is addressed to. A receiver always uses **its own** device id as the recipient,
  so an envelope reflected back to its sender, or delivered to another device, fails the tag.
- `purpose` is one of:

  | purpose       | endpoint            |
  |---------------|---------------------|
  | `clip`        | `POST /v1/clip`        |
  | `file-offer`  | `POST /v1/file/offer`  |
  | `file-finish` | `POST /v1/file/finish` |
  | `file-cancel` | `POST /v1/file/cancel` |
  | `ping`        | `POST /v1/ping` (request)  |
  | `pong`        | `POST /v1/ping` (response) |

  An envelope sealed for one endpoint fails the tag on any other (e.g. a captured offer can
  no longer cancel or finish a transfer).
- Receivers check `v` before anything else. `v != 2` gets
  `426 {"status":"upgradeRequired","minVersion":2}` on every envelope endpoint. Senders that
  receive `426`, or whose peer advertises an older `v`, show "update the other device" —
  never "unauthorized" or a re-pair prompt.

### Freshness and replay protection

Every inner payload (clip, file-offer, file-finish, file-cancel, and any later purpose such as
`ping`/`pong`) carries `"sentAt"`, the sender's clock at seal time. It lives **inside** the
ciphertext, so it is authenticated. Every platform writes it in whole-second UTC,
`yyyy-MM-ddTHH:mm:ssZ` (e.g. `2026-11-10T12:00:00Z`), and the seal helpers stamp it
automatically.

Each receiver process keeps one replay guard shared by every envelope endpoint. On every
envelope receive path the order is:

1. `v` check (426), pairing / paused checks (401).
2. AEAD open. A failed open is rejected and never touches the guard.
3. Guard check, in this order:
   - `|now − sentAt| > 300 s` → `400 {"status":"stale"}`. A missing or unparsable `sentAt`
     is stale. Stale envelopes are not remembered.
   - `(sourceDeviceId lowercase, nonce bytes)` already accepted in the last **600 s** →
     `409 {"status":"replayed"}`. The nonce is compared by its decoded bytes, not its base64
     spelling.
   - otherwise remember the pair and continue.
4. Only then any side effect (pasteboard, clip store, transfer session create/teardown).

Retention (600 s) covers the whole acceptance window: an envelope accepted at receiver time
`t` carries `sentAt ≤ t + 300`, so it is stale from `t + 600` on. Chunks are not enveloped and
are not guarded; they are bound to a session that only a fresh offer can create.

Senders that receive `400 {"status":"stale"}` show "Clock out of sync with <device>." (never
"unauthorized" or a re-pair prompt). A clock skew of up to 5 minutes still syncs.

**Freshness test vector** (all three suites assert it):

- `sentAt` for the instant `1794312000` (Unix seconds), sealed with a 456 ms fraction,
  is written as `2026-11-10T12:00:00Z` and parses back to `1794312000`.
- Receiver clock `now`: `sentAt = now − 240 s` and `now + 240 s` → ok;
  `now − 300 s` → ok (inclusive); `now − 301 s`, `now ± 1200 s` → stale.
- The same `(sourceDeviceId, nonce)` again at `now + 599 s` → replayed; at `now + 601 s`
  the entry has expired.

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

## Liveness Ping

- **Caller -> Device**: `POST /v1/ping`, body a v2 envelope with purpose `ping`, sealed to the
  device being checked. Inner JSON: `{"sentAt":"2026-11-10T12:00:00Z"}`.
- **Device -> Caller**: `200`, body a v2 envelope with purpose `pong`, source = the device,
  recipient = the caller. Inner JSON, where `pingNonce` is the ping envelope's nonce as received:
  ```json
  {
    "pingNonce": "<base64>",
    "sentAt": "2026-11-10T12:00:00Z"
  }
  ```

Responder order: `v` check (`426`), sender paired (`401`), AEAD open (`401` on failure), replay
guard (`400 {"status":"stale"}` / `409 {"status":"replayed"}`, the same shared guard as every
other envelope endpoint), then the pong. The responder's local pause switch is **not** checked:
liveness reports reachability; a paused device still refuses content with `401`.

Caller validation — the ping counts as **alive** only if all hold:

1. status `200`;
2. the body is a v2 envelope whose `sourceDeviceId` is the device that was pinged;
3. it opens with purpose `pong`, recipient = the caller's own id, under that device's `pairKey`;
4. `|now − sentAt| ≤ 300 s` (the same freshness window as the replay guard);
5. `pingNonce` decodes to the same 12 bytes as the nonce of this ping. A pong is single-use: a
   captured pong cannot answer a later ping.

Outcomes:

- **alive** → the device is online at the pinged host; if that host differs from the stored one,
  the stored host is updated; the device is removed from the outdated set (a pong proves v2).
  While it keeps ponging, an mDNS advertisement of an older `v` for its id is ignored (it would
  otherwise let anyone on the LAN block traffic to a live device).
- `426` → the device is marked outdated ("update the other device"); not online, host unchanged.
- `400 {"status":"stale"}` → **clock skew**: the device is shown "Clock out of sync" and
  reconnect / file-send errors read "Clock out of sync with <device>." (the same text as a stale
  clip). Unauthenticated, so the device is not online and its host is unchanged; a later valid
  pong clears it.
- anything else (timeout, `401`, `400`, `409`, an invalid pong) → no evidence: not online at that
  host, host unchanged.

Callers try the device's mDNS address(es) first, then its stored host. Reconnecting may also
sweep the subnet with `GET /v1/id`; hosts claiming the device's id are pinged like any other
candidate. A v1 peer cannot answer a ping, so a sweep result advertising `v < 2` (with no valid
pong anywhere) marks the device outdated; a later valid pong clears that.

**Ping/pong test vector** (all three suites assert it): the Envelope v2 vector below with
`purpose` = `ping` gives `ciphertext || tag` = `127e1dfb0b3bc52649f874034b63d5fa53c0a4886a60a1`,
and with `purpose` = `pong` gives `127e1dfb0b3bc535d219b680a4ddb08aac15ee49a426c4`.

## File Transfer Protocol

QuickDrop-style explicit file send between paired devices. Large files (videos, zips)
cannot travel as inline base64 in `POST /v1/clip` (20 MB codec cap, triple memory
copies). Instead files are split into **4 MiB plaintext chunks**, each sent as one HTTP
request with a **binary body** (`application/octet-stream`, never base64). This keeps
memory bounded — both sender and receiver stream to/from disk and never hold the whole
file or a base64 copy.

### Why chunked-per-request

All three servers (Mac `ClipServer`, Windows `TcpClipServer`, Flutter shelf) buffer the
whole request body and hardcode `Connection: close`. There is no streaming or keep-alive
without rewriting them. Chunk-per-request works within that constraint: one bounded
request body per 4 MiB slice.

### Crypto

Control messages (offer / finish / cancel) reuse the v2 envelope
`{v, sourceDeviceId, nonce, ciphertext}` sealed with the device `pairKey` (see Envelope v2),
with purposes `file-offer`, `file-finish` and `file-cancel`. Only the inner JSON differs.

Chunks are **not** enveloped. They use a per-transfer key with deterministic nonces, so
each chunk is cryptographically bound to its index — a chunk replayed at the wrong offset
fails the Poly1305 tag:

```
fileKey    = HKDF-SHA256(secret = pairKey,
                         salt   = "ClipboardSS_FileKey",   // ASCII, no NUL
                         info   = ASCII lowercase transferId,
                         L      = 32)
chunkNonce = 0x00 0x00 0x00 0x00 || uint64_big_endian(chunkIndex)   // 12 bytes
chunkBody  = ChaCha20-Poly1305(key = fileKey, nonce = chunkNonce, plaintext = slice)
           = ciphertext || 16-byte tag
```

`transferId` MUST be a freshly random UUID per transfer (nonce-reuse safety). A receiver
rejects a reused **active** `transferId` with `409`.

### fileHash

`ContentHasher` extended with a `"file"` namespace, same construction as text/image but
computed by **streaming** the file (never a whole-file read):

```
fileHash = SHA256("file" + 0x00 + fileBytes)   // lowercase hex
```

### Endpoints

All on port `51888`, same host as the clip server.

1. **`POST /v1/file/offer`** — envelope-sealed inner JSON:
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
   Responses: `200 {"status":"ready"}` · `401` unpaired · `426` upgradeRequired ·
   `400 {"status":"stale"}` · `409 {"status":"replayed"}` · `403 {"status":"declined"}`
   (reserved for a future accept prompt; v1 auto-accepts) · `409` duplicate active
   transferId · `400 {"status":"tooLarge"}` when `fileSize` exceeds free space on the
   receiver's transfers volume, minus the bytes active sessions still owe but have not yet
   allocated on disk (Swift/Dart: Σ `fileSize − bytes written`; Windows preallocates each
   `.part` to `fileSize`, so the term is 0 there), minus **500 MB** (524,288,000 bytes). When free space is
   already under that floor, even a zero-byte offer is rejected `tooLarge`; when the
   receiver cannot determine free space, transfers are not blocked ·
   `429 {"status":"tooManyTransfers"}` when the sending device already holds **8** active
   sessions (counted per authenticated `sourceDeviceId`).

### Receiver validation

Before creating any transfer state or `.part` file, receivers MUST validate the decrypted
offer. `transferId` MUST match `^[a-z0-9-]{1,64}$`; otherwise they return `400
{"status":"invalidId"}`. Offer math MUST satisfy `0 < chunkSize <= 4 MiB`,
`fileSize >= 0`, and `chunkCount == ceil(fileSize / chunkSize)` (zero for an empty
file); otherwise receivers return `400 {"status":"invalidOffer"}`. Receivers MUST
authenticate a chunk body before treating a repeated index as an idempotent duplicate.

2. **`POST /v1/file/chunk`** — headers `X-Transfer-Id`, `X-Chunk-Index`; body = raw
   `ciphertext || tag` bytes (`application/octet-stream`). Codecs lowercase header keys,
   so servers read `x-transfer-id` / `x-chunk-index`.
   Responses: `200 {"status":"ok","received":<n>}` (n = distinct chunks stored) ·
   `404` unknown/expired transferId · `400` bad index, AEAD failure, bad plaintext size or
   failed write · `410` cancelled.
   Chunks are not enveloped, so anyone who sees the plaintext `X-Transfer-Id` can post one.
   A rejected chunk therefore MUST leave the session intact (no teardown, no activity
   refresh): the genuine sender's chunks and finish still succeed. An index counts as
   received only after its bytes are written; a failed write may be retried.

3. **`POST /v1/file/finish`** — envelope-sealed `{"transferId": "...", "sentAt": "..."}`. Receiver verifies
   every chunk is present, streams the reassembled temp file through `fileHash`, and on a
   match moves it to the destination.
   Responses: `200 {"status":"complete"}` · `409 {"status":"incomplete"}` ·
   `422 {"status":"hashMismatch"}` · `422 {"status":"error"}` (hashing or move failed) ·
   `401` unpaired, paused or AEAD failure · `404` unknown transferId **or a session owned by
   a different device** (`envelope.sourceDeviceId` must equal the offer's). Both 422s
   destroy the session and its temp file.

4. **`POST /v1/file/cancel`** — envelope-sealed `{"transferId": "...", "sentAt": "..."}`;
   idempotent `200`. Like every envelope endpoint, also `400 stale` / `409 replayed`.
   `401` from a paused device; `404` when the session belongs to a different device (the
   session is left intact). On an unpaired sender or AEAD failure, Windows (C#) answers
   `401` while Swift and Dart answer `200`; cancel is best-effort and senders ignore the
   reply. Cancelled ids are remembered for **600 s** (chunks for them get
   `410`), then pruned.

### Semantics

- **Auto-accept** from paired devices in v1 (the `403 declined` path is reserved).
- **Restart-only** on failure in v1. Deterministic nonces make future resume possible via
  a `GET /v1/file/status` chunk-bitmap with no wire-format change.
- Receiver holds sessions **in memory**; chunk plaintext is written to a `.part` temp file
  at `chunkIndex * chunkSize` offsets; sessions GC after **60 s** idle.
- Every path that ends a session (cancel, hash mismatch, finalize failure, idle GC, failed
  offer setup) closes the file handle and deletes the `.part`.
- Sender streams the file in 4 MiB slices (two passes: streaming hash, then
  offer → chunks → finish) and aborts the whole transfer on any non-200, best-effort
  issuing `/v1/file/cancel`.

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

  (Same plaintext, different index ⇒ different ciphertext — this is the nonce binding.)

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
