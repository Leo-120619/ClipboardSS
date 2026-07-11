# Cross-Device Clipboard Sync Wire Protocol

## mDNS / Bonjour
- **Type**: `_clipboardss._tcp`
- **Port**: `51888`
- **TXT Record**:
  - `deviceId`: Lowercase canonical UUID string representing the device's unique identity.
  - `deviceName`: Human-readable string.
  - `v`: "1" (protocol version).

## HTTP Transport
Transport is plain HTTP (unencrypted at the transport layer). Confidentiality and authenticity are provided by the application-level encryption (ChaCha20-Poly1305).

All clip servers listen on TCP port `51888`. Devices may discover peers through mDNS or by probing local subnet hosts with `GET /v1/id`.

## Identity Probe

- **Requester -> Candidate peer**:
  `GET /v1/id`

- **Candidate peer -> Requester**:
  ```json
  {
    "deviceId": "<uuid>",
    "deviceName": "<string>",
    "v": 1
  }
  ```

## Pairing Protocol

The target must be in pairing mode before it accepts `POST /v1/pair/start`. Pairing mode shows a short-lived 6-digit code to the user. The initiator enters that code, and both peers use the ASCII bytes of the code as HKDF `info`/`sharedInfo`.

1. **Initiator -> Target**:
   `POST /v1/pair/start`
   ```json
   {
    "deviceId": "<lowercase uuid>",
     "deviceName": "<string>",
     "ephemeralPublicKey": "<base64>" // X25519 public key
   }
   ```
2. **Target -> Initiator** (on acceptance):
   `200 OK`
   ```json
   {
    "deviceId": "<lowercase uuid>",
     "deviceName": "<string>",
     "ephemeralPublicKey": "<base64>" // X25519 public key
   }
   ```
3. **Both sides compute shared secret**:
   - `sharedSecret` = X25519 DH(localPrivate, remotePublic)
   - `pairKey` (32 bytes) = HKDF-SHA256(secret=sharedSecret, salt="ClipboardSS_PairKey", info=ASCII 6-digit code)
   - `confirmCode` (6 digits) = Derived from HKDF-SHA256(secret=sharedSecret, salt="ClipboardSS_ConfirmCode", info=ASCII 6-digit code)
4. **Initiator -> Target** (confirmation proof):
   `POST /v1/pair/confirm`
   ```json
   {
    "deviceId": "<lowercase uuid>",
     "proof": "<base64>" // HMAC-SHA256(key=pairKey, message="confirm" + initiatorId + targetId)
   }
   ```
5. **Target -> Initiator**: `200 OK` (if proof is valid, pair is finalized).

## Clip Synchronization Protocol

- **Initiator -> Target**:
  `POST /v1/clip`
  Content-Type: `application/json`

  **Envelope Payload**:
  ```json
  {
    "v": 1,
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
    "sourceDeviceName": "..."
  }
  ```

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

Control messages (offer / finish / cancel) reuse the existing clip envelope
`{v, sourceDeviceId, nonce, ciphertext}` sealed with the device `pairKey` (see Clip
Synchronization Protocol). Only the inner JSON differs.

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
     "sourceDeviceName": "Leo's Mac"
   }
   ```
   Responses: `200 {"status":"ready"}` · `401` unpaired · `403 {"status":"declined"}`
   (reserved for a future accept prompt; v1 auto-accepts) · `409` duplicate active
 transferId.

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
   `404` unknown/expired transferId · `400` bad index or AEAD failure (tears down the
   session) · `410` cancelled.

3. **`POST /v1/file/finish`** — envelope-sealed `{"transferId": "..."}`. Receiver verifies
   every chunk is present, streams the reassembled temp file through `fileHash`, and on a
   match moves it to the destination.
   Responses: `200 {"status":"complete"}` · `409 {"status":"incomplete"}` ·
   `422 {"status":"hashMismatch"}` (session + temp file destroyed).

4. **`POST /v1/file/cancel`** — envelope-sealed `{"transferId": "..."}`; idempotent `200`.

### Semantics

- **Auto-accept** from paired devices in v1 (the `403 declined` path is reserved).
- **Restart-only** on failure in v1. Deterministic nonces make future resume possible via
  a `GET /v1/file/status` chunk-bitmap with no wire-format change.
- Receiver holds sessions **in memory**; chunk plaintext is written to a `.part` temp file
  at `chunkIndex * chunkSize` offsets; sessions GC after **60 s** idle.
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
