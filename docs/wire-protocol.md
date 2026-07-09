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

## Hash Parity Contract

`ContentHasher` generates hashes using SHA-256 over a namespaced payload.

Algorithm: `SHA256(namespace + 0x00 + data)`
- For text: `namespace` = "text"
- For image: `namespace` = "image"

**Test Vectors**:
1. Text: "Hello, world!"
   Hash: `f2860ecbb844a4c152aed2007055a3d41911dcb0fb7a64b996525d5b62a722e1`
   
2. Image: `[1, 2, 3]` (Bytes 0x01, 0x02, 0x03)
   Hash: `1b91e2105a1a014f55e1038235f53eae70458235d3f37da8672b563a21c04929`
