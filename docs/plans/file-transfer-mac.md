# File Transfer — Plan A (Mac machine: Swift app + Flutter companion)

**This plan executes on the Mac.** It implements the protocol spec + pinned vectors, the
Mac Swift implementation, and the full Flutter companion (iOS + Android). Flutter dev,
`flutter test`, and the iOS build all require the Mac. The Windows session executes Plan B
(`docs/plans/file-transfer-windows.md`).

The canonical protocol spec lives in `docs/wire-protocol.md` ("File Transfer Protocol"),
authored in A1. Summary reproduced below for convenience — the doc wins on any conflict.

---

## Protocol summary (canonical: `docs/wire-protocol.md`)

- **4 MiB plaintext chunks**, one HTTP request each, binary body
  (`application/octet-stream`, never base64).
- **Control messages** (offer/finish/cancel) reuse the existing envelope
  `{v, sourceDeviceId, nonce, ciphertext}` sealed with `pairKey`.
- **Chunk crypto**:
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
2. `POST /v1/file/chunk` — headers `X-Transfer-Id`, `X-Chunk-Index` (read lowercased),
   body = raw ciphertext||tag.
   → `200 {"status":"ok","received":n}` | `404` unknown | `400` bad/AEAD (teardown) |
   `410` cancelled.
3. `POST /v1/file/finish` — envelope-sealed `{transferId}`; verify all + hash-stream →
   move to `~/Downloads`. → `200` | `409 incomplete` | `422 hashMismatch`.
4. `POST /v1/file/cancel` — envelope-sealed `{transferId}`, idempotent `200`.

### Pinned vectors
- `fileHash([1,2,3])` = `53d35d037113cb046848c134d774023f716d41879185bb35b942a0472bcd70fe`
- `pairKey` `00..1f` + transferId `6f9619ff-8b86-d011-b42d-00c04fc964ff`
  → `fileKey` = `2b3f780b885ee8149fe062a00b2bb4ecc9b4326c058ad858b23009f3397a4554`
- chunk-0 body = `878b3fd3c6494ba0be8976ec7543362243af08`
- chunk-1 body = `fc5bf0de6da51d44d7e16d35ec05ed598dd1cf`

---

## A1. Protocol spec + vectors (0.5d) — **unblocks Plan B; commit & push when done**
- Add "File Transfer Protocol" section to `docs/wire-protocol.md`: endpoints,
  fileKey/nonce derivation, state machines, status-code table, auto-accept + restart-only
  notes, resume path.
- Compute the pinned vectors in Swift crypto; embed them in the doc.

## A2. Mac ClipboardCore (1.5d)
New in `Sources/ClipboardCore/`:
- `FileTransferPayload.swift` — `FileOfferPayload`/`FileFinishPayload`/`FileCancelPayload`
  (Codable, ISO-8601 like `ClipPayload`); `FileTransferConstants`. Generalize envelope
  seal/open (factor out of `ClipEnvelope.swift` without changing its public API).
- `FileTransferCrypto.swift` — `deriveFileKey`, `nonce(forChunk:)`, `sealChunk`/
  `openChunk` (CryptoKit HKDF + ChaChaPoly).
- `FileSender.swift` — mirrors `ClipSender.swift`; streams file via `FileHandle` in 4 MiB
  slices (never loads whole file), two-pass (streaming hash, then offer→chunks→finish),
  progress callback, cancellation.
- `FileReceiver.swift` — an `actor` with session map, `.part` files under
  `<storageDir>/Transfers/`, finalize → `~/Downloads` with collision-safe naming, idle GC,
  `onTransferEvent` for UI.
- Modify `ContentHasher.swift` — add streaming `fileHash` with `"file"` namespace.

Tests (`Tests/ClipboardCoreTests/`):
- `FileTransferCryptoTests.swift` — pinned vectors, wrong-index and wrong-key failures.
- Payload JSON shape tests (exact field names/formats).
- `FileReceiverTests.swift` — temp-dir based, injectable clock: happy path, out-of-order,
  duplicate idempotent, incomplete→409, corrupted chunk→teardown, hash mismatch→422 + temp
  deleted, cancel, idle GC.
- `FileSenderTests.swift` — fake transport: sequence, headers, monotonic progress, cancel
  mid-stream issues `/v1/file/cancel`, non-200 aborts.
- Loopback e2e: real sender→receiver through the real codec, ~10 MiB file (3 chunks incl.
  short last).

## A3. Mac server routes + UI (1d)
- Modify `Sources/ClipboardSS/ClipServer.swift` — add four `/v1/file/*` routes in
  `handleRequest` delegating to an injected `FileReceiver`.
- `AppModel.swift` — `transfers: [FileTransferState]`, `sendFile(url:to:)`,
  `cancelTransfer(id:)`, completion notification + Reveal in Finder.
- `DevicesView.swift` — per-device "Send File…" (`NSOpenPanel`) + Transfers section.
- `ClipboardRootView.swift` — `.onDrop(of: [.fileURL])` → send if one paired device, else
  device picker.

## A4. Flutter core + parity tests (1d)
v1 uses in-app picker, not an iOS share extension. New deps: `file_picker`,
`path_provider`, `share_plus`, optionally `wakelock_plus`.
New in `clipboard_companion/lib/core/`:
- `file_transfer_models.dart`, `file_transfer_crypto.dart` (Dart `cryptography` HKDF —
  salt maps to its `nonce:` param, as in `PairingSession`; generalize
  `CryptoEnvelopeUtils`), `file_sender.dart` (`RandomAccessFile` chunked reads, `http`
  with `Uint8List` bodies), `file_receiver.dart` (session map, event stream, injected
  destination strategy).
- Extend `content_hasher.dart` with streaming `"file"` namespace hash.
- Modify `clip_server.dart` — four shelf routes; chunk route reads raw bytes
  (`request.read()` fold, never `readAsString`); enforce max chunk body size manually.
- Modify `app_state.dart` — instantiate sender/receiver, expose `transfers`.
Tests: `test/file_transfer_parity_test.dart` (same pinned vectors + failures), payload
shape parity, receiver lifecycle (same matrix as A2), shelf handler tests, fake-transport
sender tests.

## A5. Flutter UI + save locations (1.5d)
- **Android** app-scoped external files dir + Open/Share intent (no SAF/
  `MANAGE_EXTERNAL_STORAGE`); **iOS** Documents dir + `UIFileSharingEnabled` +
  `LSSupportsOpeningDocumentsInPlace` in Info.plist.
- UI (`lib/main.dart`): per-device "Send file" icon → picker → progress; Transfers card;
  keep screen awake during transfer (`wakelock_plus`) or document foreground-only.

## A6. Mac-side verification
- `swift test` and `flutter test` pass; parity vectors byte-for-byte identical.
- Swift loopback e2e with a 10 MiB random file.
- Manual: pair Mac↔iPhone and Mac↔Android; send a >100 MB video each direction; progress
  UI, hash-verified arrival; cancel mid-transfer + temp cleanup both ends.

## Risks
- Connection-per-chunk throughput below raw sockets (~20–60 MB/s LAN) — acceptable v1.
- `NWPeerTransport` hardcodes a 10 s timeout — fine per 4 MiB chunk on LAN; parameterize
  if needed.
- Flutter iOS backgrounding kills transfers — foreground-only v1, screen-awake.
- Memory: never base64 file data, never whole-file reads.
