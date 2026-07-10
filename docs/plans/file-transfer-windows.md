# File Transfer — Plan B (Windows machine, .NET / WPF)

**This plan executes on the Windows machine.** It implements the receiver/sender +
router + WPF UI for the QuickDrop-style chunked file transfer feature. The Mac session
executes Plan A (`docs/plans/file-transfer-mac.md`).

## Prerequisite

Pull the branch after Plan A Step 1 lands. The **canonical protocol spec lives in
`docs/wire-protocol.md`** ("File Transfer Protocol" section) with pinned cross-platform
test vectors — that document, not this plan, is the source of truth. The protocol summary
reproduced below is for convenience; if it ever disagrees with `docs/wire-protocol.md`,
the doc wins.

Core coding (B1–B3) can start from this plan text in parallel with Plan A, but the parity
tests (B4) MUST use the committed vectors from `docs/wire-protocol.md` verbatim.

---

## Protocol summary (canonical: `docs/wire-protocol.md`)

- **4 MiB plaintext chunks**, one HTTP request each, binary body
  (`application/octet-stream`, never base64).
- **Control messages** (offer/finish/cancel) reuse the existing envelope
  `{v, sourceDeviceId, nonce, ciphertext}` sealed with `pairKey`.
- **Chunk crypto** (per-transfer key, deterministic nonces):
  ```
  fileKey    = HKDF-SHA256(secret=pairKey, salt="ClipboardSS_FileKey",
                           info=ASCII lowercase transferId, L=32)
  chunkNonce = 0x00000000 || uint64_big_endian(chunkIndex)   // 12 bytes
  chunkBody  = ChaCha20-Poly1305(fileKey, chunkNonce, slice) = ciphertext || 16-byte tag
  ```
- **fileHash** = `SHA256("file" + 0x00 + fileBytes)` (streamed, lowercase hex).
- `transferId` freshly random UUID per transfer; receiver rejects reused active id `409`.

### Endpoints
1. `POST /v1/file/offer` — envelope-sealed `{transferId, fileName, fileSize, mimeType,
   fileHash, chunkSize:4194304, chunkCount, createdAt, sourceDeviceName}`.
   → `200 {"status":"ready"}` | `401` unpaired | `403 declined` (reserved) | `409` dup.
2. `POST /v1/file/chunk` — headers `X-Transfer-Id`, `X-Chunk-Index` (read lowercased
   `x-transfer-id`/`x-chunk-index`), body = raw ciphertext||tag.
   → `200 {"status":"ok","received":n}` | `404` unknown | `400` bad index/AEAD (teardown)
   | `410` cancelled.
3. `POST /v1/file/finish` — envelope-sealed `{transferId}`; verify all chunks + stream
   temp through fileHash → move to Downloads.
   → `200` | `409 incomplete` | `422 hashMismatch` (session + temp destroyed).
4. `POST /v1/file/cancel` — envelope-sealed `{transferId}`, idempotent `200`.

### Pinned vectors (copy verbatim from `docs/wire-protocol.md`)
- `fileHash([1,2,3])` = `53d35d037113cb046848c134d774023f716d41879185bb35b942a0472bcd70fe`
- `pairKey` `00..1f` + transferId `6f9619ff-8b86-d011-b42d-00c04fc964ff`
  → `fileKey` = `2b3f780b885ee8149fe062a00b2bb4ecc9b4326c058ad858b23009f3397a4554`
- chunk-0 body = `878b3fd3c6494ba0be8976ec7543362243af08`
- chunk-1 body = `fc5bf0de6da51d44d7e16d35ec05ed598dd1cf`

---

## B1. Core crypto + models (0.5d)
New in `ClipboardSS.Windows/src/ClipboardSS.Core/`:
- `Models/FileTransferPayloads.cs` — offer/finish/cancel records + constants, serialized
  via `WireJson.Options` (exact field-name parity with Swift/Dart).
- `Crypto/FileTransferCrypto.cs` — `DeriveFileKey`, `NonceForChunk`, `SealChunk`/
  `OpenChunk`, reusing `HkdfSha256` and `ChaCha20Poly1305Cipher`.
- Generalize `Crypto/EnvelopeCrypto.cs` with `SealJson<T>`/`OpenJson<T>` (keep existing
  `ClipPayload` methods as thin wrappers — no public API break).
- Extend `Crypto/ContentHasher.cs` with a streaming `"file"`-namespaced hash.

## B2. Sender + receiver (0.5d)
- `Sync/FileSender.cs` — mirrors `ClipSender.cs` (`IPeerTransport`); `FileStream` chunked
  reads (4 MiB, never whole-file), two-pass (streaming hash, then offer→chunks→finish),
  `IProgress<T>`, `CancellationToken`, best-effort cancel on failure.
- `Sync/FileReceiver.cs` — session map, `.part` files at `index * chunkSize` offsets,
  idle GC (injectable clock), finalize → Downloads via
  `SHGetKnownFolderPath(FOLDERID_Downloads)` **injected as a delegate so Core stays
  testable**, collision-safe naming, transfer event callback.

## B3. Router + App UI (1d)
- Extend `IClipServerBackend` in `Protocol/ClipServerRouter.cs` with file handlers; add
  the four `/v1/file/*` routes (chunk route reads `x-transfer-id`/`x-chunk-index` and
  passes raw body bytes). `TcpClipServer.cs` unchanged.
- `AppModel.cs` — transfer collection + dispatcher marshalling, `SendFileAsync`, cancel,
  completion toast + "Open folder".
- `MainWindow.xaml` — `AllowDrop` + drop → device flyout; `DevicesWindow.xaml` — per-device
  "Send file" (file picker) + transfers list with progress/cancel.

## B4. Tests (1d) — in `tests/ClipboardSS.Core.Tests/`
- Extend `CryptoParityTests.cs` with pinned vectors from `docs/wire-protocol.md` +
  wrong-index/wrong-key failures.
- Payload JSON shape parity (like `WireJsonTests.cs`).
- Receiver lifecycle (use `TemporaryDirectory.cs`, injectable clock): happy path,
  out-of-order, duplicate idempotent, incomplete → 409, corrupt chunk → teardown, hash
  mismatch → 422 + temp deleted, cancel, idle GC.
- Extend `ClipServerRouterTests.cs`: fake backend → status codes + header parsing for all
  four routes.
- Sender with fake `IPeerTransport`: request sequence, headers, monotonic progress, cancel
  mid-stream issues `/v1/file/cancel`, non-200 aborts.
- Loopback e2e through the real `HttpCodec`, ~10 MiB file (3 chunks incl. short last).

## B5. Windows-side verification
- `dotnet test` passes; parity vectors byte-for-byte match the doc.
- Manual: pair Windows↔Mac (requires Plan A A3 deployed on the Mac); send a >100 MB file
  each direction; progress UI, hash-verified arrival in Downloads; cancel mid-transfer +
  temp cleanup.

## Risks
- **Chunk size**: don't exceed ~8 MiB. `TcpClipServer.ReadRequestAsync` re-parses the
  buffer per 64 KB read (O(n²)); flag a content-length fast-path if throughput suffers.
- **Port sharing**: Windows native app and Flutter desktop both claim 51888 (pre-existing).
- **Memory**: never base64 file data, never whole-file reads; hash and send stream.
