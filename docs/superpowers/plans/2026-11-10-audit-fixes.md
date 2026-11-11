# ClipboardSS Audit Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix every bug and security issue found in the 2026-11-10 audit of the three ClipboardSS apps (macOS Swift, Flutter companion, Windows C#).

**Architecture:** Five phases, each shippable on its own. Phase 1 is local hardening with no wire change. Phase 2 is a coordinated wire-protocol v2 (authenticated envelope metadata, replay protection, pairing limits) that must land on all three apps together. Phase 3 is pairing authentication by on-screen comparison and needs a product decision first. Phases 4 and 5 are per-app functional bugs and low-severity cleanup.

**Tech Stack:** Swift 5.9 / CryptoKit / Network.framework (macOS 14+); Dart / Flutter with `shelf` and `cryptography`; C# / .NET WPF with BouncyCastle.

**Spec:** `docs/wire-protocol.md` (current protocol; Phase 2 updates it). The audit findings are restated inside each task below, so this plan is self-contained.

## Context for a fresh session

- Repo root: `/Users/leolml/Library/Mobile Documents/com~apple~CloudDocs/Development/Clipboard SS 2`. Three apps share one LAN protocol on TCP 51888:
  - macOS: `Sources/ClipboardCore` (shared logic), `Sources/ClipboardSS` (app), `Sources/ShareExtension`; tests in `Tests/`.
  - Flutter companion (Android / iOS / Windows desktop): `clipboard_companion/lib`.
  - Windows: `ClipboardSS.Windows/src/ClipboardSS.Core`, `ClipboardSS.Windows/src/ClipboardSS.WinApp`; tests in `ClipboardSS.Windows/tests`.
- The repo lives on iCloud Drive. `git status` and whole-tree `find`/`grep` can hang for minutes; scope searches to a subdirectory.
- Line numbers below are from commit `338e25e`. Re-locate by symbol name if they have drifted.
- Evidence level: only Task 1's crash was reproduced by running code. Every other finding comes from reading the source. Each task therefore starts with a failing test that reproduces the defect; if that test passes against the current code, stop and report instead of "fixing".
- Nothing in this plan has been started.

## Global Constraints

- Run Swift tests with a scratch path outside iCloud, or codesign fails: `swift test --scratch-path "$HOME/.cache/clipboardss-build"`.
- Flutter tests: `cd clipboard_companion && flutter test`.
- Windows tests: `cd ClipboardSS.Windows && dotnet test`. The WinApp project builds only on Windows; on macOS run the Core tests only (`dotnet test tests/ClipboardSS.Core.Tests`) and mark WinApp tasks "needs Windows verification".
- Cross-platform byte parity is mandatory. Any change to envelope, pairing or file-transfer crypto lands in Swift, Dart and C# in the same phase, with shared test vectors added to `docs/wire-protocol.md` and asserted in all three test suites (existing pattern: `ClipboardSS.Windows/tests/ClipboardSS.Core.Tests/CryptoParityTests.cs`, `Tests/ClipboardCoreTests/FileTransferCryptoTests.swift`).
- Minimum macOS stays 14.0. Do not add third-party Swift dependencies.
- One commit per task. Commit messages end with the attribution line the session specifies.
- Do not log clip contents, pairing codes or key material anywhere.

## Review Focus

Conditions the tasks' main tests do not obviously cover and that will bite real users. Each has a test assigned to the task named.

1. **Device clocks differ by minutes.** Replay protection (Task 8) rejects stale messages; a phone 4 minutes off must still sync, and one 20 minutes off must get a visible "clock out of sync" status, not silent failure. Test in Task 8.
2. **One device upgraded, the other not.** A v1 peer talking to a v2 peer must see a clear "update the other device" state, not "unauthorized" or a re-pair prompt. Test in Task 7.
3. **User copies a password, then copies normal text.** The password must never reach history or peers, and the following normal copy must still be captured. Test in Task 4.
4. **Multi-GB file to a slow phone.** Finish must not time out while the receiver hashes; progress must not report failure for a file that was saved. Test in Task 12.
5. **Corrupt state file on launch.** A truncated `clips.json` must not brick the app on any platform. Test in Task 17.

---

## Phase 1 — Stop the bleeding (no wire change)

### Task 1: Mac HTTP codec rejects hostile lengths and oversized headers

**Finding (critical, reproduced):** `Content-Length: -1` crashes the app with "Can't take a prefix of negative length" at `Sources/ClipboardCore/HTTPCodec.swift:74` (requests) and `:140` (responses). Reachable without pairing via port 51888 or by answering the subnet sweep's `/v1/id` probe. Separately, `Sources/ClipboardSS/ClipServer.swift:133` buffers forever while no `\r\n\r\n` arrives.

**Files:**
- Modify: `Sources/ClipboardCore/HTTPCodec.swift`
- Modify: `Sources/ClipboardSS/ClipServer.swift` (`handleConnection`)
- Modify: `Sources/ClipboardSS/NWPeerTransport.swift`, `Sources/ClipboardSS/SubnetSweeper.swift` (response buffer cap)
- Test: `Tests/ClipboardCoreTests/HTTPCodecTests.swift` (create), `Tests/ClipboardSSTests/ClipServerTests.swift`

**Interfaces:**
- Produces: `HTTPCodec.maxHeaderSize = 16 * 1024`; new case `HTTPCodecError.headersTooLarge`. `parseRequest` / `parseResponse` throw `.invalidFormat` for a `Content-Length` that is negative or not a plain decimal integer, and `.headersTooLarge` when no header terminator appears within `maxHeaderSize` bytes.

- [ ] **Step 1: Write failing tests** in `HTTPCodecTests`:
  - `testNegativeContentLengthThrowsInvalidFormat` — parse `"POST /v1/clip HTTP/1.1\r\nContent-Length: -1\r\n\r\n"`, expect `.invalidFormat` (currently crashes the test process).
  - `testNegativeContentLengthInResponseThrowsInvalidFormat` — same for `parseResponse` with `"HTTP/1.1 200 OK\r\nContent-Length: -1\r\n\r\n"`.
  - `testNonNumericContentLengthThrowsInvalidFormat` — `Content-Length: abc`.
  - `testHeadersLargerThanLimitThrowHeadersTooLarge` — 17 KB of `A` with no terminator.
  - `testBodySliceWithNonZeroStartIndexDecodes` — body of a parsed request JSON-decodes correctly (guards the `Data` slice).
- [ ] **Step 2: Run** `swift test --scratch-path "$HOME/.cache/clipboardss-build" --filter HTTPCodecTests`. Expected: crash / FAIL.
- [ ] **Step 3: Implement** the validation in both parse functions. Return bodies as `Data(bodyData.prefix(n))` so callers never see a slice.
- [ ] **Step 4: Harden `ClipServer.handleConnection`:** respond 431 and close on `.headersTooLarge`; lower `maximumLength` per receive to 64 KB; cancel any connection that has not produced a complete request within 15 s of accept. Add `ClipServerTests.testIdleConnectionIsClosedAfterDeadline` using a short injected deadline (add an `init` parameter `requestDeadline: TimeInterval = 15`).
- [ ] **Step 5: Cap client response buffers** in `NWPeerTransport.send` and `SubnetSweeper.sendProbe` at `HTTPCodec.maxBodySize + HTTPCodec.maxHeaderSize`; fail with `URLError(.dataLengthExceedsMaximum)` beyond it.
- [ ] **Step 6: Run** the full Swift suite. Expected: PASS.
- [ ] **Step 7: Commit** `fix(mac): reject negative Content-Length and bound HTTP buffering`.

### Task 2: Sanitize image extension and validate images before storing (all three apps)

**Finding (critical on Windows):** `ClipboardSS.Windows/src/ClipboardSS.Core/Storage/ClipStore.cs:82-90` builds `"{Guid}.{extension}"` from the peer-supplied `imageExtension` and writes it with `Path.Combine`. An extension such as `x/../../../Microsoft/Windows/Start Menu/Programs/Startup/e.cmd` writes attacker bytes outside the store. `ClipReceiver.cs:48-53` stores before validating, and an undecodable image then crashes the app on every render (`UI/ImageThumbnailCache.cs:31` catches only `IOException`/`NotSupportedException`). The Mac store (`Sources/ClipboardCore/ClipStore.swift:57-70`) is not exploitable today only because the write fails; fix it the same way. Check the Dart equivalent in `clipboard_companion/lib/core/app_state.dart` and apply the same rule.

**Files:**
- Modify: `ClipboardSS.Windows/src/ClipboardSS.Core/Storage/ClipStore.cs`, `.../Sync/ClipReceiver.cs`, `ClipboardSS.Windows/src/ClipboardSS.WinApp/UI/ImageThumbnailCache.cs`, `.../App.xaml.cs`
- Modify: `Sources/ClipboardCore/ClipStore.swift`, `Sources/ClipboardCore/ClipReceiver.swift`
- Modify: `clipboard_companion/lib/core/app_state.dart` (wherever a received image is written to disk)
- Test: `ClipboardSS.Windows/tests/ClipboardSS.Core.Tests/ClipStoreTests.cs`, `.../SyncCoreTests.cs`, `Tests/ClipboardCoreTests/ClipStoreTests.swift`, `clipboard_companion/test/image_extension_test.dart` (create)

**Interfaces:**
- Produces, in each language, a pure function `sanitizedImageExtension(String) -> String`: returns the lowercased input when it matches `^[A-Za-z0-9]{1,5}$`, otherwise `"png"`.

- [ ] **Step 1: Failing tests** (same cases in all three suites): `"png"→"png"`, `"JPG"→"jpg"`, `""→"png"`, `"x/../../evil.cmd"→"png"`, `"a.b"→"png"`, `"toolongext"→"png"`. Plus `AddImageData_WithTraversalExtension_WritesInsideImagesDirectory` (C#) asserting the only new file is under `<storage>/Images/`.
- [ ] **Step 2: Failing receiver tests:** `Receive_UndecodableImage_IsRejectedAndNotStored` in C# and Swift — payload bytes `89 50 4E 47` followed by 32 random bytes; expect an error, store count unchanged, pasteboard untouched (not cleared).
- [ ] **Step 3: Run**; expected FAIL.
- [ ] **Step 4: Implement** the sanitizer and call it in each store. In each receiver, decode-validate the image first, then store, then write the pasteboard. Windows validation: `BitmapDecoder.Create` is WinApp-only, so add an `IImageValidator` interface to Core, injected into `ClipReceiver`, with a magic-number fallback (PNG, JPEG, GIF, BMP, TIFF, WebP signatures) as the Core default.
- [ ] **Step 5: Windows crash-loop guard:** `ImageThumbnailCache.Load` catches `Exception` and returns a placeholder; register `Application.DispatcherUnhandledException` in `App.xaml.cs` that logs to a file under the storage directory and sets `Handled = true`.
- [ ] **Step 6: Run** all three suites; expected PASS.
- [ ] **Step 7: Commit** `fix: sanitize received image extension and validate before storing`.

### Task 3: Pairing attempt limits and expiry (all three apps, no wire change)

**Finding (critical):** `/v1/pair/confirm` has no attempt limit; the pending key from `/v1/pair/start` outlives the 180 s code and is not checked against hosting state; an attacker-chosen `deviceId` equal to an already-paired device silently replaces that device's key. Locations: `Sources/ClipboardSS/PairingCoordinator.swift:50-108`, `clipboard_companion/lib/core/pairing_coordinator.dart:54-119`, `ClipboardSS.Windows/src/ClipboardSS.WinApp/Pairing/PairingCoordinator.cs:27-104`. Mac also compares the proof with `==` (`Sources/ClipboardCore/PairingSession.swift:75`) and logs the derived code (`PairingCoordinator.swift:166`).

**Files:** the three coordinators above, `Sources/ClipboardCore/PairingSession.swift`; tests `Tests/ClipboardSSTests/PairingCoordinatorTests.swift` (create), `clipboard_companion/test/pairing_coordinator_test.dart` (create), `ClipboardSS.Windows/tests/ClipboardSS.App.Tests/PairingCoordinatorTests.cs` (create).

**Rules to implement identically on all three targets:**
1. A hosted code accepts exactly one pending initiator. A second `/v1/pair/start` while one is pending replaces it only if it comes from the same `deviceId`; otherwise 403.
2. `/v1/pair/confirm` is rejected (401) unless the code is still active and unexpired.
3. Any failed confirm invalidates the code and clears all pending state. The user must generate a new code.
4. `stopHosting()`, expiry, and `startHosting()` all clear pending state.
5. If `deviceId` is already paired, the confirm is rejected with 409 `{"status":"alreadyPaired"}`. The user removes the device first to re-pair. (Initiator side: surface "Remove the existing pairing on the other device first".)
6. Proof comparison is constant-time.
7. Remove the log line that prints the derived code.

- [ ] **Step 1: Failing tests** (same names per platform): `confirmWithWrongProofInvalidatesCode`, `confirmAfterCodeExpiryIsRejected` (inject a clock), `confirmAfterStopHostingIsRejected`, `secondInitiatorWhilePendingIsRejected`, `confirmForAlreadyPairedDeviceIdIsRejected` (assert the stored key is unchanged), `startHostingClearsPreviousPendingState`.
- [ ] **Step 2: Run**; expected FAIL.
- [ ] **Step 3: Implement.** Mac: add `now: () -> Date` to `PairingCoordinator.init` (default `Date.init`); replace `proof == expectedProof` with `HMAC<SHA256>.isValidAuthenticationCode(proof, authenticating: message, using: pairKey)`.
- [ ] **Step 4: Run** all three suites; expected PASS.
- [ ] **Step 5: Commit** `fix(pairing): one initiator per code, invalidate on failure, no silent re-pair`.

### Task 4: Mac never captures concealed or transient pasteboard items

**Finding (critical):** `Sources/ClipboardCore/ClipboardIO.swift:69-86` (`ClipboardMonitor.poll`) and `Sources/ClipboardSS/SystemPasteboardClient.swift:15-21` ignore the nspasteboard.org markers. A copied password is written in plaintext to `~/Library/Application Support/ClipboardSS/clips.json` and broadcast to peers. `Sources/ClipboardSS/TextSnippets.swift:125-126` also writes snippets without a transient marker.

**Files:** `Sources/ClipboardCore/ClipboardIO.swift`, `Sources/ClipboardSS/SystemPasteboardClient.swift`, `Sources/ClipboardSS/TextSnippets.swift`; test `Tests/ClipboardCoreTests/ClipboardServiceTests.swift`.

**Interfaces:**
- Produces: `PasteboardSnapshot.isSensitive: Bool` (add the field to whatever snapshot type `readSnapshot()` returns). `SystemPasteboardClient` sets it when the pasteboard's types include any of `org.nspasteboard.ConcealedType`, `org.nspasteboard.TransientType`, `org.nspasteboard.AutoGeneratedType`, `com.agilebits.onepassword`.

- [ ] **Step 1: Failing tests:** `testPollSkipsSensitiveSnapshot` (store stays empty), `testPollCapturesNextNormalCopyAfterSensitiveOne` (Review Focus 3).
- [ ] **Step 2: Run** `--filter ClipboardServiceTests`; expected FAIL.
- [ ] **Step 3: Implement.** `poll()` advances `lastChangeCount` and returns without storing when `snapshot.isSensitive`. `SnippetPaster` adds `org.nspasteboard.TransientType` (empty data) alongside the snippet text.
- [ ] **Step 4: Run**; expected PASS.
- [ ] **Step 5: Commit** `fix(mac): skip concealed and transient pasteboard items`.

### Task 5: Unauthenticated memory exhaustion on Flutter and Windows listeners

**Finding (high):** `clipboard_companion/lib/core/clip_server.dart:100,135,158,195,233,246` call `request.readAsString()` with no cap. `ClipboardSS.Windows/src/ClipboardSS.WinApp/Net/TcpClipServer.cs:57-124` has no connection cap, no read timeout, and re-parses the whole buffer after every read.

**Files:** `clipboard_companion/lib/core/clip_server.dart`; `ClipboardSS.Windows/src/ClipboardSS.WinApp/Net/TcpClipServer.cs`, `ClipboardSS.Windows/src/ClipboardSS.Core/Protocol/HttpCodec.cs`; tests `clipboard_companion/test/clip_server_limits_test.dart` (create), `ClipboardSS.Windows/tests/ClipboardSS.Core.Tests/HttpCodecTests.cs` (create).

- [ ] **Step 1: Dart failing test** `oversizedBodyReturns413`: POST 21 MB to `/v1/clip`; expect 413 and that the handler never buffers past the cap. Implement a shared `Future<Uint8List> readBodyCapped(Request, {int max = 20 * 1024 * 1024})` that throws once the running total exceeds `max` (and rejects early when `Content-Length` exceeds it); use it in every handler.
- [ ] **Step 2: C# failing tests** in `HttpCodecTests`: `NegativeContentLength_IsInvalid`, `HeadersOver16KB_AreRejected`, `TryParseHead_ReturnsHeaderLengthAndContentLength`. Add `HttpCodec.TryParseHead(ReadOnlySpan<byte>, out HttpHead head)` so the server parses the head once and then reads exactly `ContentLength` more bytes.
- [ ] **Step 3: Rework `TcpClipServer.HandleClientAsync`:** 16 KB header cap; 15 s deadline for a complete request (linked `CancellationTokenSource`); at most 64 concurrent connections (`SemaphoreSlim`, excess closed immediately); no `buffer.ToArray()` per read. Also wrap the accept loop so a `SocketException` logs and continues instead of ending the loop (audit Windows #15).
- [ ] **Step 4: Run** both suites; expected PASS. WinApp change needs Windows verification.
- [ ] **Step 5: Commit** `fix: bound request size, time and concurrency on Flutter and Windows listeners`.

### Task 6: Windows click-to-paste and quit hang

**Finding (high, functional):** `ClipboardSS.Windows/src/ClipboardSS.WinApp/Win32/PasteInjector.cs:94-115` declares an `INPUT` union containing only the keyboard member, so `Marshal.SizeOf<Input>()` is 32 on x64 where Windows requires 40 and `SendInput` always fails. `App.xaml.cs:100` blocks the UI thread on `_server.DisposeAsync()` whose continuations need that thread, so Quit hangs holding port 51888.

**Files:** `.../Win32/PasteInjector.cs`, `.../App.xaml.cs`, `.../Net/TcpClipServer.cs`; test `ClipboardSS.Windows/tests/ClipboardSS.App.Tests/PasteInjectorLayoutTests.cs` (create).

- [ ] **Step 1: Failing test** `InputStruct_HasNativeSize`: assert `Marshal.SizeOf<Input>() == (IntPtr.Size == 8 ? 40 : 28)` (make the struct `internal` and expose to the test assembly via `InternalsVisibleTo`).
- [ ] **Step 2: Implement:** add `MouseInputData` (`int dx, dy; uint mouseData, dwFlags, time; IntPtr dwExtraInfo`) and `HardwareInputData` at `FieldOffset(0)` in `InputUnion`.
- [ ] **Step 3: Move server work off the UI thread:** `TcpClipServer.Start()` launches the accept loop with `Task.Run`, and every `await` in the server uses `ConfigureAwait(false)`. Handlers that touch UI state marshal through the dispatcher explicitly (they already do for `StateChanged`).
- [ ] **Step 4: Fix `OnExit`:** `Task.Run(() => _server.DisposeAsync().AsTask()).Wait(TimeSpan.FromSeconds(2))`.
- [ ] **Step 5: Verify on Windows:** click a clip → it pastes into Notepad; tray → Quit → process exits within 3 s and relaunch binds 51888.
- [ ] **Step 6: Commit** `fix(windows): correct INPUT layout and stop quit deadlock`.

---

## Phase 2 — Wire protocol v2 (all three apps in one release)

Old and new builds will not interoperate after this phase. Ship the three apps together.

### Task 7: Envelope v2 — authenticate sender, recipient and purpose

**Finding (high):** envelopes have no associated data. `sourceDeviceId` only selects the key, one key serves both directions and all message types, so an envelope can be reflected to its sender, and a captured offer envelope is accepted by `/v1/file/cancel` and `/v1/file/finish`. Locations: `Sources/ClipboardCore/ClipEnvelope.swift:61-102`, `clipboard_companion/lib/core/crypto_utils.dart:118-150`, `ClipboardSS.Windows/src/ClipboardSS.Core/Crypto/EnvelopeCrypto.cs:17-45`.

**Wire decision:**
- Envelope JSON becomes `{"v":2,"sourceDeviceId":…,"nonce":…,"ciphertext":…}`.
- AEAD associated data = UTF-8 of `"ClipboardSS/2|<purpose>|<sourceDeviceId lowercase>|<recipientDeviceId lowercase>"`.
- `purpose` ∈ `clip`, `file-offer`, `file-finish`, `file-cancel`.
- Receivers reject `v != 2` with HTTP 426 and body `{"status":"upgradeRequired","minVersion":2}`.
- mDNS TXT `v` and `/v1/id` `v` become `2`. Browsers list v1 peers but mark them "needs update" instead of hiding them.

**Files:** the three envelope files above; `Sources/ClipboardSS/ClipServer.swift`, `Sources/ClipboardCore/{ClipSender,FileSender,FileReceiver}.swift`, `Sources/ClipboardSS/PeerBrowser.swift`; Dart `clip_server.dart`, `clip_sender.dart`, `file_sender.dart`, `file_receiver.dart`, `peer_browser.dart`; C# `Protocol/ClipServerRouter.cs`, `Sync/{ClipSender,FileSender,FileReceiver}.cs`, `Net/MdnsService.cs`; `docs/wire-protocol.md`; parity tests in all three suites.

**Interfaces:**
- Produces (Swift; mirror names in Dart/C#): `enum EnvelopePurpose: String { case clip, fileOffer = "file-offer", fileFinish = "file-finish", fileCancel = "file-cancel" }`; `ClipEnvelope.seal(payload:purpose:sourceDeviceId:recipientDeviceId:pairKey:)`; `ClipEnvelope.open(_:purpose:recipientDeviceId:pairKey:)`.

- [ ] **Step 1: Add a pinned test vector** to `docs/wire-protocol.md`: key `00..1f`, nonce `000000000000000000000001`, source `11111111-1111-1111-1111-111111111111`, recipient `22222222-2222-2222-2222-222222222222`, purpose `clip`, plaintext `{"a":1}`. Generate the ciphertext once with the Swift implementation and paste the hex into the doc.
- [ ] **Step 2: Failing tests** in all three suites: `envelopeV2MatchesPinnedVector`, `openFailsWithWrongPurpose`, `openFailsWhenReflectedToSender` (swap source/recipient), `openFailsWithWrongRecipient`, `v1EnvelopeGetsUpgradeRequired` (server-level; Review Focus 2).
- [ ] **Step 3: Implement** seal/open with AAD in all three; thread `purpose` and the local device id through every call site.
- [ ] **Step 4: Peer lists** show v1 peers with a "needs update" label and refuse to send to them (`DevicesView.swift`, Flutter device list in `main.dart`, `DevicesWindow.xaml.cs`).
- [ ] **Step 5: Run** all suites; expected PASS.
- [ ] **Step 6: Commit** `feat(protocol): v2 envelopes bind sender, recipient and purpose`.

### Task 8: Replay protection

**Finding (high):** no freshness check. A sniffer can re-POST an old `/v1/clip` (receivers rewrite the clipboard even for duplicates) or replay offer+chunks+finish to re-deliver a file indefinitely.

**Wire decision:**
- Every inner payload (clip, offer, finish, cancel) gains `"sentAt": "<ISO-8601 UTC>"`, set at seal time.
- Receivers reject when `|now − sentAt| > 300 s` with 400 `{"status":"stale"}`.
- Receivers keep an in-memory set of `(sourceDeviceId, nonce)` seen in the last 600 s and reject repeats with 409 `{"status":"replayed"}`.
- Senders that receive `stale` surface "Clock out of sync with <device>".

**Files:** `Sources/ClipboardCore/ReplayGuard.swift` (create), `clipboard_companion/lib/core/replay_guard.dart` (create), `ClipboardSS.Windows/src/ClipboardSS.Core/Protocol/ReplayGuard.cs` (create); payload types and receive paths in all three; `docs/wire-protocol.md`.

**Interfaces:**
- Produces: `ReplayGuard(window: 300, retention: 600, now:)` with `check(sourceDeviceId:nonce:sentAt:) -> .ok | .stale | .replayed`. Thread-safe (Swift `actor`, C# lock, Dart single isolate).

- [ ] **Step 1: Failing tests** (all three): `freshMessageIsAccepted`, `sameNonceTwiceIsReplayed`, `sentAtFourMinutesOffIsAccepted`, `sentAtTwentyMinutesOffIsStale` (Review Focus 1), `entriesExpireAfterRetention`. Server-level: `replayedClipDoesNotTouchPasteboard`, `replayedOfferAfterFinishIsRejected`.
- [ ] **Step 2: Implement** the guard and call it immediately after a successful AEAD open, before any side effect.
- [ ] **Step 3: Sender UX** for `stale` on all three.
- [ ] **Step 4: Run**; expected PASS.
- [ ] **Step 5: Commit** `feat(protocol): reject stale and replayed envelopes`.

### Task 9: File-transfer robustness on the receiver

**Finding (medium):** any LAN host that sees the plaintext `X-Transfer-Id` can kill a transfer with one junk chunk (`Sources/ClipboardCore/FileReceiver.swift:132-140`, `clipboard_companion/lib/core/file_receiver.dart:160-175`, `ClipboardSS.Windows/src/ClipboardSS.Core/Sync/FileReceiver.cs:59-62`). `handleFinish` / `handleCancel` do not check that the envelope's device owns the session, and finish skips the paused check. No size cap or free-space check; `cancelledTransferIds` grows forever. Windows marks a chunk received before writing it (`FileReceiver.cs:66-70`), leaks the stream when `SetLength` throws (`:41-47`), and leaves a zombie session when finish fails (`:85-93`). Dart leaks a handle on concurrent identical offers (`file_receiver.dart:109-130`).

**Rules (all three):**
1. A chunk that fails authentication, has a bad index or a bad size returns 400 and leaves the session intact. Update `docs/wire-protocol.md` (it currently mandates teardown).
2. Finish and cancel require `envelope.sourceDeviceId == session.sourceDeviceId` (else 404) and a connected (not paused) device.
3. Offer is rejected with 400 `{"status":"tooLarge"}` when `fileSize` exceeds free space on the transfers volume minus 500 MB.
4. At most 8 concurrent sessions per device (429 beyond).
5. Cancelled ids are pruned after 600 s.
6. A chunk index is recorded as received only after the write succeeds.
7. Every error path closes the handle and deletes the `.part`.

**Files:** the three `FileReceiver` files; tests `Tests/ClipboardCoreTests/FileReceiverTests.swift`, `ClipboardSS.Windows/tests/ClipboardSS.Core.Tests/FileTransferTests.cs`, `clipboard_companion/test/file_receiver_test.dart` (create).

- [ ] **Step 1: Failing tests** (all three): `junkChunkDoesNotDestroySession` (send garbage, then the real chunk, then finish → 200), `finishFromDifferentPairedDeviceIsRejected`, `finishWhilePausedIsRejected`, `offerLargerThanFreeSpaceIsRejected` (inject a free-space provider), `ninthConcurrentSessionIsRejected`, `failedWriteDoesNotMarkChunkReceived` (inject a failing writer), `cancelledIdsArePruned`.
- [ ] **Step 2: Implement.** Add injectable `freeSpaceProvider` to each receiver.
- [ ] **Step 3: Run**; expected PASS.
- [ ] **Step 4: Commit** `fix(files): junk chunks no longer kill transfers; ownership, quota and cleanup`.

### Task 10: Stop trusting unauthenticated identity for routing

**Finding (medium):** a host that answers `/v1/id` or advertises mDNS with a paired device's public id is marked online and saved as that device's host (`clipboard_companion/lib/core/app_state.dart:585-606`, `ClipboardSS.Windows/src/ClipboardSS.WinApp/AppModel.cs:254-265,307,466-469`; check the Mac equivalent in `Sources/ClipboardSS/AppModel.swift` liveness code). Traffic for the real device is blackholed. Windows `MdnsService._peers` is add-only.

**Decision:** add `POST /v1/ping` — body is a v2 envelope with purpose `ping` (extend `EnvelopePurpose` with `ping` and `pong`) and inner `{"sentAt":…}`; a valid one returns 200 with a v2 envelope, purpose `pong`, sealed back to the caller. A paired device counts as online, and its host is updated, only after a successful ping/pong. `/v1/id` remains for discovering unpaired devices only.

**Files:** servers and liveness code in all three apps; `docs/wire-protocol.md`; `MdnsService.cs` (remove peers on goodbye/TTL expiry).

- [ ] **Step 1: Failing tests:** `impostorAnsweringIdIsNotMarkedOnline`, `hostIsNotUpdatedWithoutValidPong`, `validPongMarksOnlineAndUpdatesHost` (existing suites: `Tests/ClipboardSSTests/AppModelLivenessTests.swift`, `ClipboardSS.Windows/tests/ClipboardSS.App.Tests/DeviceLivenessTests.cs`; create `clipboard_companion/test/liveness_test.dart`).
- [ ] **Step 2: Implement** endpoint and liveness change on all three.
- [ ] **Step 3: Run**; expected PASS.
- [ ] **Step 4: Commit** `feat(protocol): authenticated ping for liveness and host updates`.

---

## Phase 3 — Pairing that resists an active attacker (needs a product decision)

### Task 11: Authenticate pairing by on-screen comparison

**Finding (critical, by design):** the 6-digit code is only HKDF `info`. The joining device never checks that the target knows the code, so a rogue device that answers `/v1/pair/start` receives the proof and recovers the code offline in under a second (it knows the DH secret). The Flutter and Windows apps make this easy by trying the code against every discovered host (`clipboard_companion/lib/core/app_state.dart:491-525`, `ClipboardSS.Windows/src/ClipboardSS.WinApp/AppModel.cs:198-214,562-581`). Task 3 limits online guessing but cannot fix this: with plain Diffie-Hellman plus a short code, whichever side proves knowledge first hands the other an offline oracle.

**Decision required from the owner before starting** (recommended option first):
- **Option A (recommended): compare a 6-digit number on both screens.** No new dependencies. Both devices display a number derived from the key exchange; the user confirms they match on both. UX change: one extra tap per device.
- **Option B: a real PAKE** (SPAKE2 or CPace). Keeps the type-a-code-only UX but needs elliptic-curve point arithmetic that CryptoKit and Dart's `cryptography` do not expose, i.e. third-party crypto in three languages.

**Protocol for Option A (pairing v2):**
1. Initiator → target `POST /v1/pair/start`: `{deviceId, deviceName, commitment}` where `commitment = base64(SHA256(initiatorPublicKey ‖ salt))`, `salt` 16 random bytes. The initiator's key stays hidden so neither side can grind keys toward a chosen comparison number.
2. Target → initiator: `{deviceId, deviceName, ephemeralPublicKey}`.
3. Initiator → target `POST /v1/pair/reveal`: `{deviceId, ephemeralPublicKey, salt}`. Target verifies the commitment, else 400 and the code is invalidated.
4. Both compute `pairKey` as today, with HKDF `info` = code bytes ‖ initiator public key ‖ target public key, and `confirmCode` from the same transcript (the existing derivation in `PairingSession.completePairing`).
5. Both screens show `confirmCode` and device names with Confirm / Cancel. Target confirm is local. Initiator confirm sends `POST /v1/pair/confirm` with the existing HMAC proof. Keys are stored only when both sides have confirmed; the target answers 200 only after its own user confirmed (it holds the request up to 60 s, else 408).
6. The initiator pairs with exactly one device chosen by the user. Remove the loops that try every discovered host.

**Files:** `Sources/ClipboardCore/PairingSession.swift`, `Sources/ClipboardSS/{PairingCoordinator,ClipServer,DevicesView}.swift`; Dart `pairing_coordinator.dart`, `clip_server.dart`, `app_state.dart`, pairing UI in `main.dart`; C# `Core/Crypto/PairingSession.cs`, `WinApp/Pairing/PairingCoordinator.cs`, `Core/Protocol/ClipServerRouter.cs`, `WinApp/AppModel.cs`, `UI/DevicesWindow.xaml(.cs)`; `docs/wire-protocol.md`; parity vectors.

- [ ] **Step 1: Pinned vector** in `docs/wire-protocol.md` for commitment, `pairKey` and `confirmCode` from fixed private keys, salt and code.
- [ ] **Step 2: Failing tests** (all three): `pairingV2MatchesPinnedVector`, `revealWithWrongKeyInvalidatesCode`, `keysAreNotStoredUntilBothConfirm`, `targetCancelRejectsInitiator`, `initiatorOnlyContactsSelectedPeer`, `confirmTimesOutAfter60s`.
- [ ] **Step 3: Implement** crypto and coordinators.
- [ ] **Step 4: Implement** the confirm UI on each platform (two buttons, the number in large type, both device names).
- [ ] **Step 5: Manual cross-device check:** Mac↔Android, Mac↔Windows, Windows↔Android each pair successfully, and cancelling on either side leaves no paired entry on the other.
- [ ] **Step 6: Commit** `feat(pairing): commit-reveal exchange with on-screen number comparison`.

---

## Phase 4 — Functional bugs

### Task 12: Large files fail at finish

**Finding (medium):** senders give `/v1/file/finish` the same 10 s timeout as every request while the receiver hashes the whole file first (`clipboard_companion/lib/core/file_sender.dart:39,127-137`; Mac `Sources/ClipboardSS/NWPeerTransport.swift:60` is a fixed 10 s; Windows `Net/TcpPeerTransport.cs`). The sender then sends cancel, deleting a file that was being finalized. Receivers do not refresh `lastActivity` at finish, so the 60 s GC can fire mid-hash. On Windows the finish response is additionally held behind a modal dialog (`Core/Sync/FileReceiver.cs:94` → `WinApp/AppModel.cs:586-647`).

**Files:** the three senders, three transports, three receivers, `ClipboardSS.Windows/src/ClipboardSS.WinApp/AppModel.cs`.

**Interfaces:**
- Produces: `PeerTransport.send(_:to:timeout:)` (Swift; default 10 s) and the same parameter in Dart/C#. Finish uses `max(30, fileSize / 20 MB)` seconds, capped at 600.

- [ ] **Step 1: Failing tests:** `finishUsesExtendedTimeoutForLargeFile` (fake transport records the timeout; 4 GB → 205 s), `finishRefreshesLastActivity` (GC during finish does not destroy the session), `senderDoesNotCancelAfterFinishTimeout` (on finish timeout the sender reports "unconfirmed", not failure, and sends no cancel), Windows `transferChangedIsRaisedAfterResponseAndOutsideGate`.
- [ ] **Step 2: Implement.** Windows: `FileReceiver` collects events under the gate and raises them after releasing it; `AppModel` shows dialogs via `Dispatcher.BeginInvoke`.
- [ ] **Step 3: Run**; expected PASS.
- [ ] **Step 4: Commit** `fix(files): finish timeout scales with size; no dialog under the transfer lock`.

### Task 13: Mac broadcast and echo logic

**Finding (medium):** `Sources/ClipboardSS/AppModel.swift:285-294` (`refresh`) broadcasts whenever the top clip's id changes. Deleting or expiring the top clip therefore pushes the next-older clip to every device; every received clip is echoed back to its sender; and `writeImageData` (`Sources/ClipboardSS/SystemPasteboardClient.swift:31-33`) writes TIFF, so the next poll hashes differently and stores a duplicate image. `refresh` also reads the full pasteboard every 0.75 s only to set `clipboardHasImage`, which no view reads.

**Files:** `Sources/ClipboardCore/ClipboardIO.swift`, `Sources/ClipboardCore/ClipReceiver.swift`, `Sources/ClipboardSS/{AppModel,AppDelegate,SystemPasteboardClient}.swift`; tests `Tests/ClipboardSSTests/AppModelBroadcastTests.swift` (create), `Tests/ClipboardCoreTests/ClipboardSyncTests.swift`.

**Interfaces:**
- Produces: `ClipboardMonitor.poll() throws -> ClipItem?` returning the clip captured from a genuine local copy, else nil. `AppModel.broadcastCaptured(_ clip: ClipItem)`. `refresh()` no longer broadcasts.

- [ ] **Step 1: Failing tests:** `deletingTopClipDoesNotBroadcast`, `expiringTopClipDoesNotBroadcast`, `receivedClipIsNotRebroadcast`, `copyingImageFromHistoryDoesNotCreateDuplicate`, `receivedImageDoesNotCreateDuplicate`, `localCopyIsBroadcastOnce`.
- [ ] **Step 2: Implement.** The poll timer in `AppDelegate` broadcasts only what `poll()` returns. Every app-originated pasteboard write (receive, copy from history, editor "Save & Copy", snippets) is followed by `monitor.ignoreCurrentChange()`. `writeImageData` writes the original bytes under `.png` (and `.tiff` only when the source is TIFF). Delete `clipboardHasImage` and its `readSnapshot()` call. Assign `clips` only when the store's items actually changed.
- [ ] **Step 3: Windows echo** (`clipboard_companion/lib/desktop/clipboard_sync_service.dart:67,92-110`): after writing a received image, record the hash of the bytes read back from the clipboard, not of the incoming bytes. Test `receivedJpegIsNotRebroadcast` in `clipboard_companion/test/clipboard_sync_service_test.dart` (create).
- [ ] **Step 4: Run**; expected PASS.
- [ ] **Step 5: Commit** `fix(sync): broadcast only genuine local copies; stop echo and duplicate images`.

### Task 14: Photo editor output matches the preview

**Finding (medium), all in `Sources/ClipboardSS/PhotoEditorView.swift`:**
- (a) Preview applies flip then rotation (`:291-293`); the render transform (`:969-973`, `:1014-1018`, `:1079-1083`) applies rotation then flip. With exactly one flip and any rotation, the saved image is rotated the opposite way.
- (b) Output is sized from `image.size` in points (`:963-992`), so Retina screenshots save at half resolution.
- (c) Aspect presets operate in normalized space (`:778-808`): "1:1" on a 1600×900 image changes nothing.
- (d) The preview is never cropped or re-fitted (`:288-298`), while `getTransforms` (`:1092-1107`) assumes it is, so annotations drawn after a crop or a 90° rotation of a non-square image land elsewhere in the saved file.

**Files:** `Sources/ClipboardSS/PhotoEditorView.swift`; test `Tests/ClipboardSSTests/PhotoEditorRenderTests.swift`.

- [ ] **Step 1: Failing render tests** using a 4×2-pixel image with four distinct quadrant colours:
  - `flipHorizontalThenRotate90MatchesPreviewOrder` — expected pixels computed as flip first, then rotate.
  - `retinaImageRendersAtPixelSize` — a 200×100-pixel rep with `size` 100×50 renders 200×100.
  - `squarePresetOn16by9ImageYieldsSquarePixels` — crop rect in pixels has equal width and height.
  - `annotationAfterCropLandsOnSameImagePoint` — a stroke placed over a known pixel after a crop covers that pixel in the output.
- [ ] **Step 2: Run** `--filter PhotoEditorRenderTests`; expected FAIL.
- [ ] **Step 3: Implement.** Introduce one function `editorTransform(state:imagePixelSize:) -> CGAffineTransform` used by render, annotation mapping and crop overlay; make the preview apply the same crop and fit that function assumes. Render at `cgImage` pixel dimensions. Compute presets from pixel dimensions.
- [ ] **Step 4: Run**; expected PASS. Then check by eye in the app: flip + rotate, crop + annotate, on a Retina screenshot.
- [ ] **Step 5: Commit** `fix(editor): saved image matches preview for flip, rotate, crop and Retina`.

### Task 15: Shares are not lost

**Finding (medium):** Mac `Sources/ClipboardSS/AppDelegate.swift:176,212-245` drains the share outbox synchronously at launch, before paired devices and reachability are loaded, and removes the drop even when nothing was sent. `Sources/ClipboardCore/ShareInbox.swift:109` joins manifest file names without checking for `../`. `ShareStaging/<uuid>/` is never cleaned after a send. iOS: `clipboard_companion/ios/ShareExtension/ShareViewController.swift:66-69` relies on `extensionContext.open`, and a second share overwrites `pendingShareBatchID` (plausible; reproduce first).

**Files:** `Sources/ClipboardSS/{AppDelegate,AppModel}.swift`, `Sources/ClipboardCore/ShareInbox.swift`; test `Tests/ClipboardCoreTests/ShareInboxTests.swift` (create), `Tests/ClipboardSSTests/AppModelShareTests.swift` (create); iOS `clipboard_companion/ios/ShareExtension/ShareViewController.swift`, `ios/Runner/AppDelegate.swift`, `SceneDelegate.swift`.

- [ ] **Step 1: Failing tests:** `manifestNameWithParentTraversalIsRejected`, `manifestSymlinkIsRejected`, `dropIsKeptWhenNoDeviceReachable`, `dropIsSentWhenDeviceComesOnline`, `dropOlderThan24hIsDiscarded`, `stagingFolderIsRemovedAfterSend`.
- [ ] **Step 2: Implement.** `ShareInbox` accepts only single-component names that resolve to regular files inside the drop. `AppModel` keeps a pending-shares queue processed after the first liveness pass and on every online transition; a drop is removed only after its send is handed to `FileSender`.
- [ ] **Step 3: iOS:** reproduce "share while app is running". If confirmed, store batches as a list (not a single id) in the app group and read them in `sceneDidBecomeActive`.
- [ ] **Step 4: Run**; expected PASS.
- [ ] **Step 5: Commit** `fix(share): queue shares until a device is reachable; validate inbox names`.

### Task 16: Flutter key storage and Android manifest

**Finding (medium):** pair keys are base64 in SharedPreferences (`clipboard_companion/lib/core/paired_device_store.dart:25,61`), clip history likewise (`app_state.dart:949-964`), and `AndroidManifest.xml:15-18` allows backup. Lower: `ACTION_SEND` copies arbitrary `EXTRA_STREAM` URIs with no size cap before the user picks a device (`MainActivity.kt:198-244`); `READ_MEDIA_IMAGES` / `READ_EXTERNAL_STORAGE` look unused; `MediaStore.Downloads` is used below API 29 (`MainActivity.kt:165`).

**Files:** `clipboard_companion/pubspec.yaml` (add `flutter_secure_storage`), `lib/core/paired_device_store.dart`, `android/app/src/main/AndroidManifest.xml`, `MainActivity.kt`; test `clipboard_companion/test/paired_device_store_test.dart` (create).

- [ ] **Step 1: Failing tests:** `keysAreWrittenToSecureStorageNotPrefs`, `existingPrefsKeysAreMigratedAndRemoved`.
- [ ] **Step 2: Implement** a `PairKeyStorage` abstraction with a secure-storage implementation and one-time migration from `pair_key_<id>` prefs entries.
- [ ] **Step 3: Android:** set `android:allowBackup="false"` and `android:fullBackupContent="false"`; reject `file://` share URIs and any URI resolving inside the app's own data directory; cap staged shares at 4 GB total; remove the two storage permissions if `flutter build apk` and the image/file pickers still work; guard `MediaStore.Downloads` with an API-29 check and fall back to `Environment.DIRECTORY_DOWNLOADS`.
- [ ] **Step 4: Run** `flutter test`; build an APK and share a file into the app.
- [ ] **Step 5: Commit** `fix(companion): pair keys in secure storage; tighten Android share and backup`.

---

## Phase 5 — Low severity and hygiene

### Task 17: Corrupt state files no longer block launch

**Finding:** Mac `Sources/ClipboardCore/ClipStore.swift:29-31` + `AppDelegate.swift:181-184` terminate on a bad `clips.json`; Windows `Settings/SettingsStore.cs:51`, `Core/Storage/ClipStore.cs:31-34`, `Core/Storage/PairedDeviceStore.cs:18-21` do the same.

- [ ] **Step 1: Failing tests** (Swift, C#; Dart if its loaders throw): `corruptClipsFileIsQuarantinedAndStoreStartsEmpty` — write `{"trunc` to the file, init the store, expect zero items and a sibling file named `clips.json.corrupt-<timestamp>`. Same for settings and paired devices.
- [ ] **Step 2: Implement** rename-and-continue in each loader; show a one-time notice.
- [ ] **Step 3: Commit** `fix: quarantine corrupt state files instead of refusing to start`.

### Task 18: Mac store and capture hygiene

Each bullet is one test plus one fix in the file named.
- [ ] `Sources/ClipboardCore/ClipStore.swift:146-171` — cap history at 500 unpinned clips and 500 MB of images, evicting oldest first. Test `historyIsCappedByCountAndSize`.
- [ ] `ClipStore.swift:102-124` — delete the file before mutating memory in `delete()` / `cleanupExpiredClips()`. Test `failedFileDeleteLeavesStoreConsistent`.
- [ ] `Sources/ClipboardSS/AppDelegate.swift:192-201` — a throwing `poll()` must not skip cleanup/refresh for that tick, and must retry the same change count once. Test `pollFailureIsRetriedOnce`.
- [ ] `Sources/ClipboardSS/ScreenshotCaptureService.swift:24-25` — delete the temp PNG after import; add a re-entrancy guard in `AppModel.captureScreenshot()` (`AppModel.swift:690`). Test `screenshotTempFileIsRemoved`.
- [ ] `Sources/ClipboardSS/TextSnippets.swift:113-123` — guard the save with `savedItems == nil` so a second hotkey press does not overwrite the saved clipboard. Test `secondSnippetPasteKeepsOriginalClipboard`.
- [ ] `Sources/ClipboardSS/ClipboardRootView.swift:80-83` — give the editor sheet item a stable id (the clip id).
- [ ] `Sources/ClipboardSS/AppModel.swift:522-591` — capture the transfer id, not the array index, across `runModal()`; record the batch decision before presenting the panel; handle an existing destination name. Test `receivePromptUsesTransferIdNotIndex`.
- [ ] `Sources/ClipboardSS/ClipCard.swift:206-218` — cache decoded thumbnails by path so the 0.75 s tick does not re-decode.
- [ ] `Sources/ClipboardCore/FileReceiver.swift:247-254` — set the `com.apple.quarantine` attribute on received files. Test `receivedFileIsQuarantined`.
- [ ] `Sources/ClipboardSS/ShortcutRecorderView.swift:95-101`, `HotKeyManager.swift:149-171` — reject shortcuts that collide with ⌘V or another registered shortcut; surface `RegisterEventHotKey` failures in Preferences. Extend `HotKeyManagerTests`.
- [ ] `Sources/ClipboardSS/SubnetSweeper.swift:11-35` — derive the host range from the real netmask (cap at /22) and use the primary active interface, not a hard-coded `en0`. Extend `SubnetSweeperTests`.
- [ ] Debug log (`Sources/ClipboardCore/ClipEnvelope.swift:4-22`, `Sources/ClipboardSS/PeerBrowser.swift:7-23`) — move from world-readable `/tmp/clipboardss_debug.log` to `~/Library/Logs/ClipboardSS/debug.log` with mode 0600, and keep one implementation.
- [ ] Commit `chore(mac): history caps, temp cleanup, quarantine, shortcut and sweep fixes`.

### Task 19: Windows hygiene

- [ ] `Core/Selection/ScreenTextSelectionState.cs:328-373` — replace the ±4 px tolerant comparer with line bucketing followed by a strict sort. Test `SortIsStableForNearlyAlignedWords`.
- [ ] `WinApp/Win32/ClipboardInterop.cs:61` — bound `PtrToStringUni` by `GlobalSize / 2`.
- [ ] `WinApp/Win32/ClipboardInterop.cs:40-52` — when both text and image formats are present, prefer text. Test via an injected format list.
- [ ] `Core/Sync/FileReceiver.cs:114` — strip `:` and reserved device names (`NUL`, `CON`, `COM1`…) from received file names; write a `Zone.Identifier` stream with `ZoneId=3` on received files.
- [ ] `WinApp/App.xaml.cs:45-73` — if activation redirect throws, exit instead of starting a second full instance.
- [ ] `WinApp/Pairing/PairingCoordinator.cs` / `UI/DevicesWindow` — hide the code when it expires.
- [ ] `WinApp/AppModel.cs` — cap `_transfers` at the 100 most recent.
- [ ] `scripts/package-msix.ps1:76` — stop passing the PFX password on the `signtool` command line (use the certificate store thumbprint via `/sha1`).
- [ ] Commit `chore(windows): sort stability, clipboard bounds, file-name and packaging hardening`.

### Task 20: Flutter hygiene

- [ ] `lib/core/file_receiver.dart:193-194` — serialize chunk writes per session (a per-session `Future` chain). Test `concurrentChunksAreWrittenInOrder`.
- [ ] `lib/core/clip_server.dart:129` — return a generic 500 body, not the exception text.
- [ ] `lib/core/subnet_sweeper.dart:105-115` — prefer the interface holding the default route; derive range from the mask.
- [ ] `lib/main.dart:1065-1067` — "Send to Mac" on an existing clip must not insert a duplicate with the same id.
- [ ] `lib/main.dart:188-203,1255-1280` — after the file picker returns, await the resumed liveness probe before showing the device chooser.
- [ ] Commit `chore(companion): chunk write ordering, error bodies, sweep and picker fixes`.

### Task 21: Build and CI

**Finding:** `.github/workflows/build.yml:19-20` runs `scripts/build_app.sh`, which exits 1 without a signing identity (`build_app.sh:101-114`), so the test step never runs. `build_app.sh:25` expands an empty array under `set -u` (fails on stock bash 3.2). Actions are pinned to tags. `scripts/create_dmg.sh:49` says the DMG can be shared although it is self-signed and un-notarized.

- [ ] Reorder the workflow so `swift test` runs first; set `CODESIGN_IDENTITY=-` (ad-hoc) for the CI build step; add `dotnet test ClipboardSS.Windows/tests/ClipboardSS.Core.Tests` and `flutter test` jobs.
- [ ] Pin actions to commit SHAs.
- [ ] Guard the empty-array expansion with `${arr[@]+"${arr[@]}"}`.
- [ ] Correct the DMG message to say other Macs will see a Gatekeeper warning until the app is notarized.
- [ ] Push a branch and confirm the workflow goes green.
- [ ] Commit `ci: run tests on all three apps; fix build script on stock bash`.

### Task 22: Documentation

- [ ] Rewrite `docs/wire-protocol.md` to describe protocol v2 as built in Phases 2–3 (envelope AAD, `sentAt`, replay rules, `/v1/ping`, pairing v2, chunk-error semantics), keeping every pinned vector.
- [ ] Add a "Security model" section stating what is and is not protected: LAN-only, plaintext HTTP framing, metadata visible (device ids, transfer ids, sizes), history stored unencrypted at rest.
- [ ] Commit `docs: wire protocol v2 and security model`.

---

## Order and dependencies

- Phase 1 tasks are independent of each other and can run in parallel.
- Task 7 → Task 8 → Tasks 9, 10 (all need the v2 envelope API).
- Task 11 needs the owner's Option A/B decision and should follow Task 7 so pairing v2 ships in the same incompatible release.
- Phases 4 and 5 are independent of Phases 2 and 3, except Task 12 touches the transports that Task 7 also edits; do Task 7 first if both are in flight.
- Suggested releases: **R1** = Phase 1 (compatible with current builds). **R2** = Phases 2 + 3 together (breaking; all three apps). **R3** = Phases 4 + 5.
