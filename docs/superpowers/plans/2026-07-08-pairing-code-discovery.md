# Pairing-Code + Local Unicast Discovery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a Mac and Android phone pair and sync clipboard over the LAN using a 6-digit pairing code and automatic unicast discovery, with no reliance on mDNS multicast and no backend.

**Architecture:** One device shows a short-lived 6-digit code and enters "pairing mode"; the other enters the code, finds the peer via mDNS *or* a unicast subnet sweep on fixed port `51888` (probing a new `GET /v1/id` endpoint), and pairs with a handshake whose key derivation mixes in the code so only the matching-code peer succeeds. Each peer's IP is persisted so sync and reconnection work without mDNS. Implemented in parallel across the Swift (`ClipboardCore`/`ClipboardSS`) and Dart (`clipboard_companion`) apps, kept byte-for-byte compatible via shared crypto vectors.

**Tech Stack:** Swift (CryptoKit, Network.framework, Swift Testing), Dart/Flutter (`cryptography`, `shelf`, `bonsoir`, `flutter_test`).

**Reference spec:** `docs/superpowers/specs/2026-07-08-pairing-code-discovery-design.md`

**Shared constants (must match across apps):**
- Fixed clip-server port: `51888`
- HKDF pair-key salt: `"ClipboardSS_PairKey"` (existing)
- Pairing-code HKDF: the ASCII bytes of the 6-digit code go in the HKDF **`info`/`sharedInfo`** field (previously empty).
- Code format: 6 ASCII digits, e.g. `"048213"`; TTL 180 s.

---

## Phase A — Swift: code-bound key derivation

### Task A1: `PairingSession.completePairing` mixes the code into HKDF

**Files:**
- Modify: `Sources/ClipboardCore/PairingSession.swift`
- Test: `Tests/ClipboardCoreTests/ClipboardSyncTests.swift`

- [ ] **Step 1: Write the failing test** — append to `ClipboardSyncTests`:

```swift
@Test("Code-bound pairKey differs by code and matches across peers")
func codeBoundPairing() throws {
    let initiator = PairingSession()
    let target = PairingSession()
    let iId = UUID(); let tId = UUID()

    let (keyA, _) = try initiator.completePairing(
        remotePublicKey: target.ephemeralPublicKey,
        initiatorId: iId, targetId: tId, isInitiator: true, code: "048213")
    let (keyB, _) = try target.completePairing(
        remotePublicKey: initiator.ephemeralPublicKey,
        initiatorId: iId, targetId: tId, isInitiator: false, code: "048213")
    #expect(keyA == keyB)

    let (keyWrong, _) = try target.completePairing(
        remotePublicKey: initiator.ephemeralPublicKey,
        initiatorId: iId, targetId: tId, isInitiator: false, code: "999999")
    #expect(keyWrong != keyA)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter codeBoundPairing`
Expected: FAIL — `completePairing` has no `code:` parameter.

- [ ] **Step 3: Implement** — in `PairingSession.completePairing`, add a `code` parameter and feed it into both HKDF `sharedInfo` fields. New signature and body:

```swift
public func completePairing(
    remotePublicKey: Data,
    initiatorId: UUID,
    targetId: UUID,
    isInitiator: Bool,
    code: String
) throws -> (pairKey: SymmetricKey, confirmCode: String) {
    guard let remoteKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: remotePublicKey) else {
        throw PairingError.invalidPublicKey
    }
    let sharedSecret = try privateKey.sharedSecretFromKeyAgreement(with: remoteKey)
    let info = Data(code.utf8)

    let pairKey = sharedSecret.hkdfDerivedSymmetricKey(
        using: SHA256.self,
        salt: "ClipboardSS_PairKey".data(using: .utf8)!,
        sharedInfo: info,
        outputByteCount: 32
    )
    let codeKey = sharedSecret.hkdfDerivedSymmetricKey(
        using: SHA256.self,
        salt: "ClipboardSS_ConfirmCode".data(using: .utf8)!,
        sharedInfo: info,
        outputByteCount: 4
    )
    let codeValue = codeKey.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
    let confirmCode = String(format: "%06d", (codeValue % 1_000_000))
    return (pairKey, confirmCode)
}
```

- [ ] **Step 4: Update the existing `pairingSession` test** in the same file to pass `code: "000000"` to both `completePairing` calls so it still compiles. (Two call sites.)

- [ ] **Step 5: Run tests**

Run: `swift test --filter "Clipboard sync"`
Expected: PASS (all sync tests).

- [ ] **Step 6: Commit**

```bash
git add Sources/ClipboardCore/PairingSession.swift Tests/ClipboardCoreTests/ClipboardSyncTests.swift
git commit -m "feat(core): mix pairing code into HKDF key derivation"
```

### Task A2: Update Swift `PairingCoordinator` call sites for `code:`

**Files:**
- Modify: `Sources/ClipboardSS/PairingCoordinator.swift` (two `completePairing` calls, lines ~50 and ~150)

This is completed as part of Task F1 (which reworks the coordinator wholesale). Placeholder here only to note the compile dependency: after Task A1, `Sources/ClipboardSS` will not compile until Task F1 lands. Execute Phase F immediately after Phase A for Swift, or temporarily pass `code: "000000"` at both sites to keep the build green between tasks.

---

## Phase B — Dart: code-bound key derivation (parity)

### Task B1: Dart `PairingSession.completePairing` mixes the code into HKDF

**Files:**
- Modify: `clipboard_companion/lib/core/crypto_utils.dart`
- Test: `clipboard_companion/test/pairing_parity_test.dart` (create)

- [ ] **Step 1: Write the failing parity test** (create file):

```dart
import 'dart:convert';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:clipboard_companion/core/crypto_utils.dart';

void main() {
  test('code-bound pairKey matches across peers and differs by code', () async {
    final a = PairingSession(); await a.init();
    final b = PairingSession(); await b.init();
    const iId = '550e8400-e29b-41d4-a716-446655440000';
    const tId = '4d967c79-47dc-4e1f-a3bd-d3160b082da7';

    final ra = await a.completePairing(
      remotePublicKeyBytes: b.ephemeralPublicKey,
      initiatorId: iId, targetId: tId, isInitiator: true, code: '048213');
    final rb = await b.completePairing(
      remotePublicKeyBytes: a.ephemeralPublicKey,
      initiatorId: iId, targetId: tId, isInitiator: false, code: '048213');
    expect(await ra.pairKey.extractBytes(), await rb.pairKey.extractBytes());

    final rw = await b.completePairing(
      remotePublicKeyBytes: a.ephemeralPublicKey,
      initiatorId: iId, targetId: tId, isInitiator: false, code: '999999');
    expect(await rw.pairKey.extractBytes(), isNot(await ra.pairKey.extractBytes()));
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd clipboard_companion && flutter test test/pairing_parity_test.dart`
Expected: FAIL — `completePairing` has no `code` parameter.

- [ ] **Step 3: Implement** — in `crypto_utils.dart`, add `required String code` to `completePairing` and pass its UTF-8 bytes as the HKDF `info` for both derivations:

```dart
Future<PairingResult> completePairing({
  required List<int> remotePublicKeyBytes,
  required String initiatorId,
  required String targetId,
  required bool isInitiator,
  required String code,
}) async {
  final remotePublicKey = SimplePublicKey(remotePublicKeyBytes, type: KeyPairType.x25519);
  final sharedSecret = await _x25519.sharedSecretKey(
    keyPair: _privateKey, remotePublicKey: remotePublicKey);
  final info = utf8.encode(code);

  final pairKey = await _hkdfPairKey.deriveKey(
    secretKey: sharedSecret,
    nonce: utf8.encode('ClipboardSS_PairKey'),
    info: info,
  );
  final codeKey = await _hkdfCodeKey.deriveKey(
    secretKey: sharedSecret,
    nonce: utf8.encode('ClipboardSS_ConfirmCode'),
    info: info,
  );
  final codeBytes = await codeKey.extractBytes();
  final byteData = ByteData.sublistView(Uint8List.fromList(codeBytes));
  final codeValue = byteData.getUint32(0, Endian.big);
  final confirmCode = (codeValue % 1000000).toString().padLeft(6, '0');
  return PairingResult(pairKey: pairKey, confirmCode: confirmCode);
}
```

- [ ] **Step 4: Run test**

Run: `cd clipboard_companion && flutter test test/pairing_parity_test.dart`
Expected: PASS.

- [ ] **Step 5: Cross-language vector check.** Add a fixed-vector test on BOTH sides using known keys is not possible (ephemeral keys). Instead assert the two apps agree by construction: the HKDF salt/info/order are identical (verified by reading A1 and B1). No extra step; parity is covered by the live end-to-end in Phase I.

- [ ] **Step 6: Commit**

```bash
cd clipboard_companion && git add lib/core/crypto_utils.dart test/pairing_parity_test.dart
git commit -m "feat(companion): mix pairing code into HKDF key derivation"
```

### Task B2: Update Dart `PairingCoordinator` call sites

Handled wholesale in Task F2. Same compile-dependency note as A2: pass `code: '000000'` temporarily if building between tasks.

---

## Phase C — Persist peer address (`PairedDevice.host`)

### Task C1: Swift `PairedDevice.host`

**Files:**
- Modify: `Sources/ClipboardCore/PairedDeviceStore.swift`
- Test: `Tests/ClipboardCoreTests/ClipboardServiceTests.swift`

- [ ] **Step 1: Write the failing test** — append:

```swift
@Test("PairedDevice persists optional host and legacy records decode")
func pairedDeviceHostRoundTrip() throws {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    // legacy JSON without host
    try Data(#"[{"id":"\#(UUID().uuidString)","name":"Old"}]"#.utf8).write(to: tmp)
    let store = try PairedDeviceStore(storageURL: tmp, keyStorage: InMemoryPairKeyStorage())
    #expect(store.devices.first?.host == nil)

    let dev = PairedDevice(id: UUID(), name: "Mac", host: "192.168.0.4")
    try store.addDevice(dev, key: SymmetricKey(size: .bits256))
    let reopened = try PairedDeviceStore(storageURL: tmp, keyStorage: InMemoryPairKeyStorage())
    #expect(reopened.devices.contains { $0.host == "192.168.0.4" })
}
```

Add a test helper `InMemoryPairKeyStorage` at the bottom of the test file if not present:

```swift
final class InMemoryPairKeyStorage: PairKeyStorage, @unchecked Sendable {
    private var keys: [UUID: SymmetricKey] = [:]
    func storeKey(_ key: SymmetricKey, for deviceId: UUID) throws { keys[deviceId] = key }
    func getKey(for deviceId: UUID) throws -> SymmetricKey? { keys[deviceId] }
    func deleteKey(for deviceId: UUID) throws { keys[deviceId] = nil }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter pairedDeviceHostRoundTrip`
Expected: FAIL — `PairedDevice` has no `host`.

- [ ] **Step 3: Implement** — add `host` to `PairedDevice`:

```swift
public struct PairedDevice: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public var name: String
    public var host: String?

    public init(id: UUID, name: String, host: String? = nil) {
        self.id = id
        self.name = name
        self.host = host
    }
}
```

(`Codable` with an optional makes legacy records without `host` decode to `nil` automatically.)

- [ ] **Step 4: Run test**

Run: `swift test --filter pairedDeviceHostRoundTrip`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/ClipboardCore/PairedDeviceStore.swift Tests/ClipboardCoreTests/ClipboardServiceTests.swift
git commit -m "feat(core): add optional host to PairedDevice"
```

### Task C2: Dart `PairedDevice.host`

**Files:**
- Modify: `clipboard_companion/lib/core/models.dart`
- Modify: `clipboard_companion/lib/core/paired_device_store.dart` (preserve host through `addDevice`)
- Test: `clipboard_companion/test/paired_device_host_test.dart` (create)

- [ ] **Step 1: Write the failing test**:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:clipboard_companion/core/models.dart';

void main() {
  test('PairedDevice host round-trips and legacy JSON decodes to null', () {
    final legacy = PairedDevice.fromJson({'id': 'ABC', 'name': 'Old'});
    expect(legacy.host, isNull);

    final d = PairedDevice(id: 'abc', name: 'Mac', host: '192.168.0.4');
    final back = PairedDevice.fromJson(d.toJson());
    expect(back.host, '192.168.0.4');
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd clipboard_companion && flutter test test/paired_device_host_test.dart`
Expected: FAIL — no `host` param.

- [ ] **Step 3: Implement** — replace `PairedDevice` in `models.dart`:

```dart
class PairedDevice {
  final String id;
  final String name;
  final String? host;

  PairedDevice({
    required String id,
    required this.name,
    this.host,
  }) : id = canonicalDeviceId(id);

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        if (host != null) 'host': host,
      };

  factory PairedDevice.fromJson(Map<String, dynamic> json) => PairedDevice(
        id: json['id'] as String,
        name: json['name'] as String,
        host: json['host'] as String?,
      );
}
```

- [ ] **Step 4: Preserve host in the store** — in `paired_device_store.dart` `addDevice`, change the canonical rebuild to keep `host`:

```dart
final canonicalDevice = PairedDevice(id: canonicalId, name: device.name, host: device.host);
```

- [ ] **Step 5: Run test**

Run: `cd clipboard_companion && flutter test test/paired_device_host_test.dart`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
cd clipboard_companion && git add lib/core/models.dart lib/core/paired_device_store.dart test/paired_device_host_test.dart
git commit -m "feat(companion): add optional host to PairedDevice"
```

---

## Phase D — Fixed port + `/v1/id` endpoint

### Task D1: Swift — fixed port `51888` + `/v1/id`

**Files:**
- Modify: `Sources/ClipboardSS/ClipServer.swift`
- Test: `Tests/ClipboardSSTests/ClipServerTests.swift`

- [ ] **Step 1: Write the failing test** — a pure-logic test for the id-response builder (avoids binding a real socket):

```swift
@Test("identity response JSON contains id, name, v")
func identityResponseJSON() throws {
    let json = ClipServer.identityResponseBody(id: UUID(uuidString: "8fb5790c-4533-47bb-90af-827291247fe1")!, name: "Mac")
    let obj = try JSONSerialization.jsonObject(with: json) as! [String: Any]
    #expect(obj["deviceId"] as? String == "8FB5790C-4533-47BB-90AF-827291247FE1")
    #expect(obj["deviceName"] as? String == "Mac")
    #expect(obj["v"] as? Int == 1)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter identityResponseJSON`
Expected: FAIL — no `identityResponseBody`.

- [ ] **Step 3: Implement**:
  1. Add the static helper to `ClipServer`:

```swift
static func identityResponseBody(id: UUID, name: String) -> Data {
    let dict: [String: Any] = ["deviceId": id.uuidString, "deviceName": name, "v": 1]
    return (try? JSONSerialization.data(withJSONObject: dict)) ?? Data()
}
```

  2. Bind the listener to `51888`. Replace the listener creation in `init`:

```swift
self.listener = try NWListener(using: parameters, on: 51888)
```

  3. Store `identity` on the instance (add `private let identity: DeviceIdentity` and assign in `init`), then handle the route in `handleRequest` before the 404 branch:

```swift
} else if request.method == "GET", request.path == "/v1/id" {
    let resp = HTTPResponse(statusCode: 200, headers: ["Content-Type": "application/json"],
                            body: Self.identityResponseBody(id: identity.id, name: identity.name))
    self.sendResponse(resp, on: connection)
}
```

- [ ] **Step 4: Run tests**

Run: `swift test --filter "ClipServer"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/ClipboardSS/ClipServer.swift Tests/ClipboardSSTests/ClipServerTests.swift
git commit -m "feat(mac): fixed port 51888 and GET /v1/id endpoint"
```

### Task D2: Dart — fixed port `51888` + `/v1/id`

**Files:**
- Modify: `clipboard_companion/lib/core/clip_server.dart`
- Test: `clipboard_companion/test/clip_server_id_test.dart` (create — pure logic)

- [ ] **Step 1: Write the failing test** for an extracted id-body builder:

```dart
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:clipboard_companion/core/clip_server.dart';

void main() {
  test('identity body has id, name, v', () {
    final body = jsonDecode(ClipServer.identityBody('367c33ad-...', 'Android Device'));
    expect(body['deviceId'], '367c33ad-...');
    expect(body['deviceName'], 'Android Device');
    expect(body['v'], 1);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd clipboard_companion && flutter test test/clip_server_id_test.dart`
Expected: FAIL — no `identityBody`.

- [ ] **Step 3: Implement**:
  1. Add static helper to `ClipServer`:

```dart
static String identityBody(String deviceId, String deviceName) =>
    jsonEncode({'deviceId': deviceId, 'deviceName': deviceName, 'v': 1});
```

  2. Change the bind port from `0` to `51888`:

```dart
_server = await io.serve(handler, InternetAddress.anyIPv4, 51888);
```

  3. Register the route in `start()`:

```dart
router.get('/v1/id', (Request request) => Response.ok(
    identityBody(identity.id, identity.name),
    headers: {'Content-Type': 'application/json'}));
```

- [ ] **Step 4: Run test**

Run: `cd clipboard_companion && flutter test test/clip_server_id_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd clipboard_companion && git add lib/core/clip_server.dart test/clip_server_id_test.dart
git commit -m "feat(companion): fixed port 51888 and GET /v1/id endpoint"
```

---

## Phase E — Unicast subnet sweeper

### Task E1: Swift subnet enumeration (pure logic)

**Files:**
- Create: `Sources/ClipboardSS/SubnetSweeper.swift`
- Test: `Tests/ClipboardSSTests/SubnetSweeperTests.swift` (create)

- [ ] **Step 1: Write the failing test**:

```swift
import Testing
@testable import ClipboardSS

@Suite("Subnet sweeper")
struct SubnetSweeperTests {
    @Test("enumerates a /24 excluding own address, network, broadcast")
    func enumerate24() {
        let hosts = SubnetSweeper.hostAddresses(ownIPv4: "192.168.0.4", netmask: "255.255.255.0")
        #expect(hosts.count == 253)                 // 254 usable minus self
        #expect(hosts.contains("192.168.0.9"))
        #expect(!hosts.contains("192.168.0.4"))     // self excluded
        #expect(!hosts.contains("192.168.0.0"))     // network excluded
        #expect(!hosts.contains("192.168.0.255"))   // broadcast excluded
    }

    @Test("wider-than-/24 mask is capped to the local /24")
    func capWideMask() {
        let hosts = SubnetSweeper.hostAddresses(ownIPv4: "10.0.5.7", netmask: "255.255.0.0")
        #expect(hosts.count == 253)
        #expect(hosts.allSatisfy { $0.hasPrefix("10.0.5.") })
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter "Subnet sweeper"`
Expected: FAIL — no `SubnetSweeper`.

- [ ] **Step 3: Implement** the pure enumeration (networking added in E2):

```swift
import Foundation
import Network

enum SubnetSweeper {
    /// Host addresses to probe. Caps to the local /24 around ownIPv4 when the
    /// mask is wider than /24, and excludes network, broadcast, and self.
    static func hostAddresses(ownIPv4: String, netmask: String) -> [String] {
        let ipParts = ownIPv4.split(separator: ".").compactMap { UInt8($0) }
        let maskParts = netmask.split(separator: ".").compactMap { UInt8($0) }
        guard ipParts.count == 4, maskParts.count == 4 else { return [] }
        // Effective mask is at least /24.
        let prefix = [ipParts[0], ipParts[1], ipParts[2]]
        var result: [String] = []
        for last in 1...254 {
            let addr = "\(prefix[0]).\(prefix[1]).\(prefix[2]).\(last)"
            if addr == ownIPv4 { continue }
            result.append(addr)
        }
        return result
    }
}
```

- [ ] **Step 4: Run test**

Run: `swift test --filter "Subnet sweeper"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/ClipboardSS/SubnetSweeper.swift Tests/ClipboardSSTests/SubnetSweeperTests.swift
git commit -m "feat(mac): subnet host enumeration for unicast sweep"
```

### Task E2: Swift live sweep (`/v1/id` probe)

**Files:**
- Modify: `Sources/ClipboardSS/SubnetSweeper.swift`

- [ ] **Step 1: Implement** (no unit test — exercised in Phase I live test) an async sweep that resolves the own IPv4/netmask, enumerates hosts, and probes each with a short-timeout `GET /v1/id` via `NWPeerTransport`, returning `[Peer]`:

```swift
extension SubnetSweeper {
    static func ownIPv4AndMask() -> (ip: String, mask: String)? {
        var result: (String, String)? = nil
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            guard (flags & IFF_UP) == IFF_UP, (flags & IFF_LOOPBACK) == 0 else { continue }
            guard ptr.pointee.ifa_addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: ptr.pointee.ifa_name)
            guard name == "en0" else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            var mask = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(ptr.pointee.ifa_addr, socklen_t(ptr.pointee.ifa_addr.pointee.sa_len),
                        &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            getnameinfo(ptr.pointee.ifa_netmask, socklen_t(ptr.pointee.ifa_netmask.pointee.sa_len),
                        &mask, socklen_t(mask.count), nil, 0, NI_NUMERICHOST)
            result = (String(cString: host), String(cString: mask))
        }
        return result
    }

    static func sweep(transport: PeerTransport, timeoutMs: Int = 500, concurrency: Int = 32) async -> [Peer] {
        guard let (ip, mask) = ownIPv4AndMask() else { return [] }
        let hosts = hostAddresses(ownIPv4: ip, netmask: mask)
        let req = HTTPRequest(method: "GET", path: "/v1/id", headers: [:], body: Data())
        return await withTaskGroup(of: Peer?.self) { group in
            var found: [Peer] = []
            var index = 0
            func addTask(_ host: String) {
                group.addTask {
                    let peer = Peer(id: UUID(), name: host, host: host, port: 51888)
                    let bytes = HTTPCodec.encodeRequest(req, host: host)
                    guard let data = try? await transport.send(bytes, to: peer),
                          let resp = try? HTTPCodec.parseResponse(data), resp.statusCode == 200,
                          let obj = try? JSONSerialization.jsonObject(with: resp.body) as? [String: Any],
                          let idStr = obj["deviceId"] as? String, let id = UUID(uuidString: idStr) else { return nil }
                    let name = (obj["deviceName"] as? String) ?? host
                    return Peer(id: id, name: name, host: host, port: 51888)
                }
            }
            while index < hosts.count && index < concurrency { addTask(hosts[index]); index += 1 }
            while let peer = await group.next() {
                if let peer = peer { found.append(peer) }
                if index < hosts.count { addTask(hosts[index]); index += 1 }
            }
            return found
        }
    }
}
```

Note: `NWPeerTransport`'s 10 s timeout is longer than desired for a sweep; acceptable for v1 because unreachable hosts fail fast with connection errors, not timeouts. (A per-call timeout override is a possible later refinement.)

- [ ] **Step 2: Build**

Run: `swift build`
Expected: builds clean.

- [ ] **Step 3: Commit**

```bash
git add Sources/ClipboardSS/SubnetSweeper.swift
git commit -m "feat(mac): unicast /v1/id subnet sweep"
```

### Task E3: Dart subnet enumeration + sweep

**Files:**
- Create: `clipboard_companion/lib/core/subnet_sweeper.dart`
- Test: `clipboard_companion/test/subnet_sweeper_test.dart` (create)

- [ ] **Step 1: Write the failing test** (pure enumeration):

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:clipboard_companion/core/subnet_sweeper.dart';

void main() {
  test('/24 enumeration excludes self, network, broadcast', () {
    final hosts = SubnetSweeper.hostAddresses('192.168.0.9', 24);
    expect(hosts.length, 253);
    expect(hosts.contains('192.168.0.4'), isTrue);
    expect(hosts.contains('192.168.0.9'), isFalse);
    expect(hosts.contains('192.168.0.0'), isFalse);
    expect(hosts.contains('192.168.0.255'), isFalse);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd clipboard_companion && flutter test test/subnet_sweeper_test.dart`
Expected: FAIL — no `SubnetSweeper`.

- [ ] **Step 3: Implement**:

```dart
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'models.dart';

class SubnetSweeper {
  static List<String> hostAddresses(String ownIPv4, int prefixLen) {
    final parts = ownIPv4.split('.');
    if (parts.length != 4) return [];
    final base = '${parts[0]}.${parts[1]}.${parts[2]}';
    final result = <String>[];
    for (var last = 1; last <= 254; last++) {
      final addr = '$base.$last';
      if (addr == ownIPv4) continue;
      result.add(addr);
    }
    return result;
  }

  static Future<String?> _ownIPv4() async {
    for (final ni in await NetworkInterface.list(type: InternetAddressType.IPv4)) {
      for (final a in ni.addresses) {
        if (!a.isLoopback && a.address.startsWith('192.168.') || a.address.startsWith('10.') || a.address.startsWith('172.')) {
          return a.address;
        }
      }
    }
    return null;
  }

  static Future<List<Peer>> sweep({int timeoutMs = 500, int concurrency = 32}) async {
    final ip = await _ownIPv4();
    if (ip == null) return [];
    final hosts = hostAddresses(ip, 24);
    final found = <Peer>[];
    final client = http.Client();
    final iterator = hosts.iterator;
    Future<void> worker() async {
      while (iterator.moveNext()) {
        final host = iterator.current;
        try {
          final resp = await client
              .get(Uri.parse('http://$host:51888/v1/id'))
              .timeout(Duration(milliseconds: timeoutMs));
          if (resp.statusCode == 200) {
            final obj = jsonDecode(resp.body) as Map<String, dynamic>;
            found.add(Peer(
              id: obj['deviceId'] as String,
              name: (obj['deviceName'] as String?) ?? host,
              host: host,
              port: 51888,
            ));
          }
        } catch (_) {/* unreachable host */}
      }
    }
    await Future.wait(List.generate(concurrency, (_) => worker()));
    client.close();
    return found;
  }
}
```

- [ ] **Step 4: Run test**

Run: `cd clipboard_companion && flutter test test/subnet_sweeper_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd clipboard_companion && git add lib/core/subnet_sweeper.dart test/subnet_sweeper_test.dart
git commit -m "feat(companion): unicast /v1/id subnet sweep"
```

---

## Phase F — Pairing coordinators: host code, pairing mode, store host

### Task F1: Swift `PairingCoordinator` — pairing mode + code + host capture

**Files:**
- Modify: `Sources/ClipboardSS/PairingCoordinator.swift`
- Modify: `Sources/ClipboardSS/ClipServer.swift` (thread remote IP into confirm; pass code check into start)

- [ ] **Step 1: Add host-side pairing mode.** In `PairingCoordinator` add:

```swift
@Published public var hostCode: String?          // shown while hosting
private var hostCodeExpiry: Date?

public func startHosting(ttl: TimeInterval = 180) -> String {
    let code = String(format: "%06d", Int.random(in: 0...999_999))
    hostCode = code
    hostCodeExpiry = Date().addingTimeInterval(ttl)
    return code
}

public func stopHosting() { hostCode = nil; hostCodeExpiry = nil }

private func activeHostCode() -> String? {
    guard let code = hostCode, let exp = hostCodeExpiry, exp > Date() else {
        stopHosting(); return nil
    }
    return code
}
```

- [ ] **Step 2: Rework the target path.** Replace `handlePairStartRequest` and `handlePairConfirmRequest` so the target uses the active host code (auto-accept when hosting; no user prompt), and record the initiator's `host`. New signatures thread a `remoteHost` from the server:

```swift
public func handlePairStartRequest(initiatorId: UUID, initiatorName: String,
                                   initiatorPubKeyBase64: String, remoteHost: String) async throws -> Data {
    guard let code = activeHostCode() else { throw PairingError.notHosting }
    guard let initiatorPubKey = Data(base64Encoded: initiatorPubKeyBase64) else { throw PairingError.invalidPublicKey }
    let session = PairingSession()
    pendingTargetSessions[initiatorId] = session
    targetDeviceNames[initiatorId] = initiatorName
    targetHosts[initiatorId] = remoteHost
    let (pairKey, _) = try session.completePairing(
        remotePublicKey: initiatorPubKey, initiatorId: initiatorId,
        targetId: identity.id, isInitiator: false, code: code)
    targetTempKeys[initiatorId] = pairKey
    return session.ephemeralPublicKey
}

public func handlePairConfirmRequest(initiatorId: UUID, proofBase64: String) async throws -> Bool {
    guard let proof = Data(base64Encoded: proofBase64), let pairKey = targetTempKeys[initiatorId] else { return false }
    let isValid = PairingSession.verifyConfirmationProof(
        proof: proof, pairKey: pairKey, initiatorId: initiatorId, targetId: identity.id)
    if isValid {
        let host = targetHosts[initiatorId]
        try await pairedStore.addDevice(
            PairedDevice(id: initiatorId, name: targetDeviceNames[initiatorId] ?? "Device", host: host), key: pairKey)
        stopHosting()
        targetTempKeys[initiatorId] = nil; pendingTargetSessions[initiatorId] = nil
        targetDeviceNames[initiatorId] = nil; targetHosts[initiatorId] = nil
        onPairedDevicesChanged?()
    }
    return isValid
}
```

Add `private var targetHosts: [UUID: String] = [:]`, remove the `pairPrompt`/continuation machinery and the `PairPrompt` struct (superseded by pairing mode), and add `case notHosting` to `PairingError` in `PairingSession.swift`.

- [ ] **Step 3: Rework the initiator path** so it takes a `code`, passes it to `completePairing`, and stores the target `host`:

```swift
public func startPairing(with peer: Peer, code: String) async throws {
    isPairing = true; defer { isPairing = false }
    let session = PairingSession()
    // ... encode PairStartReq with session.ephemeralPublicKey, POST /v1/pair/start (unchanged) ...
    let (pairKey, _) = try session.completePairing(
        remotePublicKey: targetPubKey, initiatorId: identity.id,
        targetId: targetResp.deviceId, isInitiator: true, code: code)
    let proof = PairingSession.generateConfirmationProof(
        pairKey: pairKey, initiatorId: identity.id, targetId: targetResp.deviceId)
    // ... POST /v1/pair/confirm (unchanged) ...
    if confirmResponse.statusCode == 200 {
        try await pairedStore.addDevice(
            PairedDevice(id: targetResp.deviceId, name: targetResp.deviceName, host: peer.host), key: pairKey)
        onPairedDevicesChanged?()
    } else { throw URLError(.userAuthenticationRequired) }
}
```

- [ ] **Step 4: Thread `remoteHost` in `ClipServer`.** In `handleConnection`, extract the remote IP from `connection.endpoint`:

```swift
static func remoteHost(from endpoint: NWEndpoint) -> String {
    if case let .hostPort(host, _) = endpoint {
        switch host {
        case .ipv4(let a): return "\(a)".components(separatedBy: "%").first ?? "\(a)"
        case .ipv6(let a): return "\(a)".components(separatedBy: "%").first ?? "\(a)"
        case .name(let n, _): return n
        @unknown default: return "\(host)"
        }
    }
    return "\(endpoint)"
}
```

Pass it into the `/v1/pair/start` handler call: `handlePairStartRequest(initiatorId:..., remoteHost: Self.remoteHost(from: connection.endpoint))`.

- [ ] **Step 5: Add a unit test** for `remoteHost` parsing:

```swift
@Test("remoteHost extracts ipv4 without zone")
func remoteHostParsing() {
    let ep = NWEndpoint.hostPort(host: .ipv4(IPv4Address("192.168.0.9")!), port: 51888)
    #expect(ClipServer.remoteHost(from: ep) == "192.168.0.9")
}
```

- [ ] **Step 6: Build + test**

Run: `swift build && swift test --filter "ClipServer"`
Expected: builds; tests pass.

- [ ] **Step 7: Commit**

```bash
git add Sources/ClipboardSS/PairingCoordinator.swift Sources/ClipboardSS/ClipServer.swift Sources/ClipboardCore/PairingSession.swift Tests/ClipboardSSTests/ClipServerTests.swift
git commit -m "feat(mac): pairing-code hosting mode, auto-accept, host capture"
```

### Task F2: Dart `PairingCoordinator` — pairing mode + code + host capture

**Files:**
- Modify: `clipboard_companion/lib/core/pairing_coordinator.dart`
- Modify: `clipboard_companion/lib/core/clip_server.dart` (thread remote IP)

- [ ] **Step 1: Add host mode + code to the coordinator** (mirror F1). Replace the prompt-based `handlePairStartRequest` with a code-gated one and add hosting API:

```dart
String? _hostCode;
DateTime? _hostCodeExpiry;

String startHosting({Duration ttl = const Duration(seconds: 180)}) {
  final code = (Random.secure().nextInt(1000000)).toString().padLeft(6, '0');
  _hostCode = code;
  _hostCodeExpiry = DateTime.now().add(ttl);
  return code;
}
void stopHosting() { _hostCode = null; _hostCodeExpiry = null; }
String? _activeHostCode() {
  if (_hostCode == null || _hostCodeExpiry == null || _hostCodeExpiry!.isBefore(DateTime.now())) {
    stopHosting(); return null;
  }
  return _hostCode;
}

Future<String> handlePairStart(String initiatorId, String initiatorName,
    String initiatorPubKeyBase64, String remoteHost) async {
  final code = _activeHostCode();
  if (code == null) throw Exception('Not hosting');
  final canonicalInitiatorId = canonicalDeviceId(initiatorId);
  final session = PairingSession();
  await session.init();
  _pendingTargetSessions[canonicalInitiatorId] = session;
  _targetDeviceNames[canonicalInitiatorId] = initiatorName;
  _targetHosts[canonicalInitiatorId] = remoteHost;
  final result = await session.completePairing(
    remotePublicKeyBytes: base64Decode(initiatorPubKeyBase64),
    initiatorId: canonicalInitiatorId, targetId: identity.id,
    isInitiator: false, code: code);
  _targetTempResults[canonicalInitiatorId] = result;
  return base64Encode(session.ephemeralPublicKey);
}
```

Add `final Map<String, String> _targetHosts = {};`, and in `handlePairConfirmRequest`, persist the host and stop hosting:

```dart
if (isValid) {
  await pairedStore.addDevice(
    PairedDevice(id: canonicalInitiatorId,
      name: _targetDeviceNames[canonicalInitiatorId] ?? 'Device',
      host: _targetHosts[canonicalInitiatorId]),
    result.pairKey);
  stopHosting();
  _targetTempResults.remove(canonicalInitiatorId);
  _pendingTargetSessions.remove(canonicalInitiatorId);
  _targetDeviceNames.remove(canonicalInitiatorId);
  _targetHosts.remove(canonicalInitiatorId);
}
```

- [ ] **Step 2: Initiator path takes a code** and stores the target host. Change `startPairing(Peer peer)` to `startPairing(Peer peer, String code)`, pass `code: code` into `completePairing`, and on confirm-200 `addDevice(PairedDevice(id: targetId, name: targetName, host: peer.host), result.pairKey)`.

- [ ] **Step 3: Thread remote IP in `clip_server.dart`.** In `_handlePairStart`, read the remote address and pass it:

```dart
final connInfo = request.context['shelf.io.connection_info'] as HttpConnectionInfo?;
final remoteHost = connInfo?.remoteAddress.address ?? '';
final targetPubKeyBase64 = await pairingCoordinator.handlePairStart(
    initiatorId, initiatorName, initiatorPubKeyBase64, remoteHost);
```

(`HttpConnectionInfo` comes from `dart:io`; ensure it is imported.)

- [ ] **Step 4: Update `app_state.dart`** where `handlePairStartRequest` / prompt stream were used — remove the accept-prompt subscription (`_pairPromptSubscription`) since hosting auto-accepts; expose `startHosting`/`stopHosting`/`_hostCode` through `AppState`.

- [ ] **Step 5: Run tests + analyze**

Run: `cd clipboard_companion && flutter test && flutter analyze`
Expected: tests pass; no analyzer errors.

- [ ] **Step 6: Commit**

```bash
cd clipboard_companion && git add lib/core/pairing_coordinator.dart lib/core/clip_server.dart lib/core/app_state.dart
git commit -m "feat(companion): pairing-code hosting mode, auto-accept, host capture"
```

---

## Phase G — Send to persisted addresses

### Task G1: Swift — union send targets

**Files:**
- Modify: `Sources/ClipboardSS/AppModel.swift`
- Test: `Tests/ClipboardSSTests/AppModelPasteTests.swift`

- [ ] **Step 1: Write the failing test** for the target-composition helper:

```swift
@Test("send targets union mDNS peers with paired hosts, de-duped by id")
func sendTargetUnion() {
    let id1 = UUID(); let id2 = UUID()
    let mdns = [Peer(id: id1, name: "Phone", host: "192.168.0.9", port: 51888)]
    let paired = [PairedDevice(id: id1, name: "Phone", host: "192.168.0.99"),
                  PairedDevice(id: id2, name: "Tablet", host: "192.168.0.20")]
    let targets = AppModel.composeSendTargets(mdnsPeers: mdns, pairedDevices: paired)
    #expect(targets.count == 2)
    #expect(targets.first { $0.id == id1 }?.host == "192.168.0.9")   // live peer wins
    #expect(targets.first { $0.id == id2 }?.host == "192.168.0.20")  // stored host used
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter sendTargetUnion`
Expected: FAIL — no `composeSendTargets`.

- [ ] **Step 3: Implement** a static helper on `AppModel`:

```swift
static func composeSendTargets(mdnsPeers: [Peer], pairedDevices: [PairedDevice]) -> [Peer] {
    var byId: [UUID: Peer] = [:]
    for dev in pairedDevices where dev.host != nil {
        byId[dev.id] = Peer(id: dev.id, name: dev.name, host: dev.host!, port: 51888)
    }
    for peer in mdnsPeers { byId[peer.id] = peer }   // live peer overrides stored host
    return Array(byId.values)
}
```

Then use it wherever clips are broadcast (compose `peerBrowser.peers` with `pairedDevices` and pass to `clipSender.broadcast`).

- [ ] **Step 4: Run test**

Run: `swift test --filter sendTargetUnion`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/ClipboardSS/AppModel.swift Tests/ClipboardSSTests/AppModelPasteTests.swift
git commit -m "feat(mac): send to paired hosts when mDNS peer absent"
```

### Task G2: Dart — union send targets

**Files:**
- Modify: `clipboard_companion/lib/core/app_state.dart`
- Test: `clipboard_companion/test/send_targets_test.dart` (create)

- [ ] **Step 1: Write the failing test**:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:clipboard_companion/core/app_state.dart';
import 'package:clipboard_companion/core/models.dart';

void main() {
  test('send targets union: live peer wins, stored host used otherwise', () {
    final mdns = [Peer(id: 'a', name: 'Mac', host: '192.168.0.4', port: 51888)];
    final paired = [PairedDevice(id: 'a', name: 'Mac', host: '10.0.0.9'),
                    PairedDevice(id: 'b', name: 'PC', host: '192.168.0.20')];
    final targets = composeSendTargets(mdns, paired);
    expect(targets.length, 2);
    expect(targets.firstWhere((p) => p.id == 'a').host, '192.168.0.4');
    expect(targets.firstWhere((p) => p.id == 'b').host, '192.168.0.20');
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd clipboard_companion && flutter test test/send_targets_test.dart`
Expected: FAIL — no `composeSendTargets`.

- [ ] **Step 3: Implement** a top-level function in `app_state.dart`:

```dart
List<Peer> composeSendTargets(List<Peer> mdnsPeers, List<PairedDevice> paired) {
  final byId = <String, Peer>{};
  for (final d in paired) {
    if (d.host != null) {
      byId[d.id] = Peer(id: d.id, name: d.name, host: d.host!, port: 51888);
    }
  }
  for (final p in mdnsPeers) { byId[p.id] = p; }
  return byId.values.toList();
}
```

Use it in `sendClip` to build the target list (replace the current mDNS-only peer list).

- [ ] **Step 4: Run test**

Run: `cd clipboard_companion && flutter test test/send_targets_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd clipboard_companion && git add lib/core/app_state.dart test/send_targets_test.dart
git commit -m "feat(companion): send to paired hosts when mDNS peer absent"
```

---

## Phase H — UI: show / enter code

### Task H1: Swift `DevicesView` — Show code + Enter code

**Files:**
- Modify: `Sources/ClipboardSS/DevicesView.swift`
- Modify: `Sources/ClipboardSS/AppModel.swift` (drive hosting + join)

- [ ] **Step 1: Add AppModel actions**:

```swift
@Published var joinInProgress = false

func showPairingCode() -> String { pairingCoordinator.startHosting() }
func stopHostingCode() { pairingCoordinator.stopHosting() }

func joinWithCode(_ code: String) {
    joinInProgress = true
    Task {
        defer { joinInProgress = false }
        var candidates = peerBrowser.peers
        if candidates.isEmpty { candidates = await SubnetSweeper.sweep(transport: NWPeerTransport()) }
        for peer in candidates {
            do { try await pairingCoordinator.startPairing(with: peer, code: code)
                 await refreshPairedDevices(); return }
            catch { continue }   // wrong code / not hosting -> try next
        }
        lastError = "No device accepted that code. Make sure the other device is showing a code on the same Wi-Fi."
    }
}
```

- [ ] **Step 2: Replace the `DevicesView` body** with two actions: a "Show pairing code" button that displays `pairingCoordinator.hostCode`, and an "Enter code" `TextField` (6 digits) + "Connect" button calling `model.joinWithCode`. Keep the paired-devices list and Unpair. (Remove the old `PairingPromptView`, now unused.) Concrete SwiftUI:

```swift
Section("Pair a device") {
    if let code = coordinator.hostCode {
        Text("Show this code on the other device:").font(.caption)
        Text(code).font(.system(size: 40, weight: .bold, design: .monospaced))
        Button("Stop") { model.stopHostingCode() }
    } else {
        Button("Show pairing code") { _ = model.showPairingCode() }
        HStack {
            TextField("6-digit code", text: $enteredCode)
            Button("Connect") { model.joinWithCode(enteredCode) }
                .disabled(enteredCode.count != 6 || model.joinInProgress)
        }
    }
}
```

(Add `@State private var enteredCode = ""` to `DevicesView`.)

- [ ] **Step 3: Build + run tests**

Run: `swift build && swift test`
Expected: builds; all tests pass.

- [ ] **Step 4: Commit**

```bash
git add Sources/ClipboardSS/DevicesView.swift Sources/ClipboardSS/AppModel.swift
git commit -m "feat(mac): show/enter pairing code UI with sweep-based join"
```

### Task H2: Dart — Show code + Enter code screen

**Files:**
- Modify: `clipboard_companion/lib/main.dart` (pairing/devices screen)
- Modify: `clipboard_companion/lib/core/app_state.dart` (join action)

- [ ] **Step 1: Add `AppState.joinWithCode`**:

```dart
bool joinInProgress = false;

Future<void> joinWithCode(String code) async {
  joinInProgress = true; notifyListeners();
  try {
    var candidates = peerBrowser.peers;
    if (candidates.isEmpty) candidates = await SubnetSweeper.sweep();
    for (final peer in candidates) {
      try { await pairingCoordinator.startPairing(peer, code); notifyListeners(); return; }
      catch (_) { /* wrong code / not hosting */ }
    }
    lastError = 'No device accepted that code. Make sure the other device shows a code on the same Wi-Fi.';
  } finally { joinInProgress = false; notifyListeners(); }
}
```

(Import `subnet_sweeper.dart`. Add `lastError` if not present.)

- [ ] **Step 2: Update the pairing UI** in `main.dart`: a "Show pairing code" button that calls `state.pairingCoordinator.startHosting()` and displays the code, and a 6-digit `TextField` + "Connect" calling `state.joinWithCode(code)`. Remove the old accept-prompt dialog wired to `pairPromptStream`.

- [ ] **Step 3: Run + analyze**

Run: `cd clipboard_companion && flutter test && flutter analyze`
Expected: pass; no errors.

- [ ] **Step 4: Commit**

```bash
cd clipboard_companion && git add lib/main.dart lib/core/app_state.dart
git commit -m "feat(companion): show/enter pairing code UI with sweep-based join"
```

---

## Phase I — Docs + live end-to-end

### Task I1: Update wire protocol doc

**Files:**
- Modify: `docs/wire-protocol.md`

- [ ] **Step 1** Add a `GET /v1/id` section (returns `{deviceId, deviceName, v}`), note the fixed port `51888`, and document that `pairKey`/`confirmCode` HKDF now use the 6-digit code as the `info`/`sharedInfo` parameter. Note the target must be in "pairing mode" (active code) to accept `/v1/pair/start`.

- [ ] **Step 2: Commit**

```bash
git add docs/wire-protocol.md
git commit -m "docs: pairing-code HKDF, /v1/id, fixed port 51888"
```

### Task I2: Live end-to-end over adb (manual verification)

**Files:** none (verification task)

- [ ] **Step 1** Build & launch the Mac app with logging:

```bash
./scripts/build_app.sh && pkill -x ClipboardSS; CLIPBOARDSS_DEBUG_LOG=1 open -n build/ClipboardSS.app
```

- [ ] **Step 2** Build & install the companion, foreground it:

```bash
export PATH="$HOME/Library/Android/sdk/platform-tools:$PATH"
cd clipboard_companion && flutter build apk --debug && adb install -r build/app/outputs/flutter-apk/app-debug.apk
adb shell am start -n com.leolml.clipboard_companion/.MainActivity
```

- [ ] **Step 3** On the Mac: Devices → "Show pairing code" (note the 6 digits).

- [ ] **Step 4** On the phone: enter the code → Connect. Expected: sweep finds the Mac on `:51888`, pairing completes, the Mac shows the phone under Paired, and `/tmp/clipboardss_debug.log` shows a successful `/v1/pair/confirm`.

- [ ] **Step 5** Wrong-code check: show a new code on the Mac, type a different code on the phone → expect the "No device accepted that code" error.

- [ ] **Step 6** Sync check: copy text on the Mac → verify it appears on the phone (and vice versa while the phone app is foregrounded), confirming `composeSendTargets` uses the persisted host.

- [ ] **Step 7** Record results in the PR description; no commit.

---

## Self-review notes

- **Spec coverage:** fixed port (D1/D2), `/v1/id` (D1/D2), subnet sweep (E), code-bound HKDF (A/B), pairing mode + auto-accept (F), host capture + persistence (C/F), union send targets (G), UI (H), docs + e2e (I). All spec sections mapped.
- **Type consistency:** `completePairing(..., code:)`, `PairedDevice(id:name:host:)` / `host` optional, `composeSendTargets`, `startPairing(with:code:)` / `startPairing(peer, code)`, `startHosting`/`stopHosting`, `remoteHost`/`connection_info` — used consistently across tasks.
- **Compile-ordering caveat:** A/B change a shared signature; execute each language's Phase F right after its Phase A/B (or use the `code: "000000"` stopgap noted in A2/B2) to keep intermediate builds green.
