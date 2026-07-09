# Pairing-Code + Local Unicast Discovery — Design

**Date:** 2026-07-08
**Status:** Approved (design)

## Problem

On the user's network (ARRIS-D3A7 gateway), mDNS multicast (`224.0.0.251:5353`)
is not relayed between the two Wi-Fi clients, so neither the macOS app nor the
Android companion can discover the other — even though both are on the same
`/24` subnet and **unicast works perfectly** (verified live: `ping` OK, and a
direct HTTP `POST` from the Mac to the phone's clip server returned a real
`401 Unauthorized` from `package:shelf`).

Discovery is not the only mDNS dependency: **`ClipSender` also gets the peer's
IP from the live discovery browser**, so clip sync fails without mDNS even after
a successful pairing, because paired devices are stored by id + name only —
never their address.

Manual IP entry was rejected as not release-quality. The chosen approach: a
short **pairing code** plus **automatic local unicast discovery**, with no
backend, no accounts, and data staying peer-to-peer on the LAN.

## Non-goals

- **Cross-network sync / any backend.** Local Wi-Fi only. No rendezvous server,
  no relay, no accounts.
- **Android background suspension.** When the companion app is not foregrounded
  (screen off / another app on top), Android suspends its networking (inbound
  TCP dropped, mDNS + sweep stop). Reliable phone→Mac sync while backgrounded
  needs an Android foreground service — separate follow-up, not in this work.
- **QR pairing.** Not needed once code + auto-discovery works; can layer on later.
- **SPAKE2 / full PAKE.** v1 mixes the code into HKDF (see §4). Upgrading to a
  true PAKE is a later hardening with the same overall design.

## Design overview

Replace "discover via mDNS, then pair with a DH-derived confirm code" with:
"one device shows a short pre-shared code; the other enters it, finds the peer
by unicast sweep (mDNS as a fast path), and pairs using a handshake that only
succeeds when both sides hold the same code." Persist each peer's address so
sync and reconnection work without mDNS.

### 1. Fixed clip-server port `51888`

Both apps pin the clip server to `51888` (was ephemeral). Needed for the sweep
(a known port to probe) and for stable stored addresses. mDNS still advertises,
now with this stable port.

- macOS `ClipServer`: bind `NWListener` to port `51888`.
- Android `ClipServer`: `io.serve(handler, InternetAddress.anyIPv4, 51888)`.
- **Port conflict:** if `51888` is taken, surface a clear user-visible error
  ("Sync port 51888 is in use"); do not fail silently.

### 2. `GET /v1/id` identity endpoint

New unauthenticated endpoint on both clip servers returning
`{ "deviceId": <uuid>, "deviceName": <string>, "v": 1 }`. Used by a sweeping
device to recognize a clipboard peer among arbitrary hosts. Leaks only the same
info already broadcast in the mDNS TXT record, so no new exposure.

### 3. Unicast subnet sweep (discovery fallback)

A new discovery module in each app:

1. Determine the device's own IPv4 address + netmask on the active interface.
2. Enumerate host addresses on that subnet. **Cap at a `/24` (254 hosts):** if
   the mask is wider than `/24`, only sweep the local `/24` around the device's
   own address and log a note (home networks are `/24`; avoids scanning 65k hosts).
3. Parallel TCP connect to `host:51888` with bounded concurrency (~32) and a
   short per-host timeout (~500 ms); on connect, `GET /v1/id`; collect valid
   clipboard peers as `Peer(id, name, host, port: 51888)`.
4. Discovery order: try mDNS first; if it yields the target, skip the sweep. The
   sweep runs on demand (entering a code, or reconnect), never continuously.

### 4. Pairing code handshake

Roles are symmetric; either device can host or join.

**Host** (taps "Show pairing code"): generates a random **6-digit numeric code**
with a short TTL (default 3 min), enters pairing mode, and displays it. While in
pairing mode it accepts a code-bound pairing handshake; outside it, pairing
attempts are refused.

**Joiner** (taps "Enter code", types the 6 digits):
1. Build candidate peers = mDNS peers ∪ swept peers (§3).
2. For each candidate, run the existing X25519 exchange, but **mix the code into
   key derivation**: `pairKey = HKDF(sharedSecret, salt="ClipboardSS_PairKey",
   info=code)` (and the confirm code / proof derive from this code-bound key).
   Only a peer holding the same code derives the matching key, so only its proof
   verifies; every other host silently fails and is discarded.
3. First candidate whose proof verifies is the intended device → finalize.

**Wire protocol impact:** the pair/start + pair/confirm exchange is unchanged in
shape; only the key-derivation `info` gains the code, and the target must be "in
pairing mode" with a live code to accept. `docs/wire-protocol.md` updated to
document the code-bound HKDF and `/v1/id`.

**Reused crypto:** builds directly on the existing `PairingSession`
(`completePairing`, `generateConfirmationProof`) — the only change is threading
the code into the HKDF `info` on both Swift and Dart sides so their derivations
stay identical (existing cross-platform parity tests extended with a code-bound
vector).

### 5. Persist peer address; capture at pairing time

`PairedDevice` gains `host: String?` (last-known IP) in both apps
(`Codable`/JSON backward-compatible; missing → `null`).

- Joiner stores the candidate IP it paired with.
- Host stores the joiner's IP read from the incoming TCP connection
  (macOS: `NWConnection.endpoint`; Android shelf:
  `request.context['shelf.io.connection_info']` → `HttpConnectionInfo.remoteAddress`).

### 6. Sending uses persisted addresses

Both `ClipSender`s send to the **union of** (a) live mDNS peers and (b) paired
devices with a stored `host` at `host:51888`, de-duplicated by `deviceId`
(prefer a live discovered address, else stored `host`). A paired device with a
known IP receives clips even with mDNS fully blocked. On send failure to a stored
`host`, trigger a re-sweep to refresh a possibly-changed IP.

## Components touched

| Component | Change |
|---|---|
| `ClipboardCore/PairedDeviceStore.swift` | `PairedDevice.host`; round-trip |
| `ClipboardCore/PairingSession.swift` | code-bound HKDF `info` |
| `ClipboardSS/ClipServer.swift` | fixed port; `/v1/id`; pairing-mode gate; remote IP into confirm |
| `ClipboardSS/PairingCoordinator.swift` | host code + pairing mode/TTL; store `host` both paths |
| `ClipboardSS/SubnetSweeper.swift` (new) | unicast sweep + `/v1/id` probe |
| `ClipboardSS/DevicesView.swift` | "Show pairing code" / "Enter code" UI |
| `ClipboardSS/AppModel.swift` | compose send targets = mDNS ∪ paired-with-host; drive sweep |
| `companion/core/paired_device_store.dart` | `PairedDevice.host`; JSON compat |
| `companion/core/crypto_utils.dart` | code-bound HKDF `info` |
| `companion/core/clip_server.dart` | fixed port; `/v1/id`; pairing-mode gate; remote IP into confirm |
| `companion/core/pairing_coordinator.dart` | host code + pairing mode/TTL; store `host` both paths |
| `companion/core/subnet_sweeper.dart` (new) | unicast sweep + `/v1/id` probe |
| `companion/core/clip_sender.dart` / `app_state.dart` | union send targets; drive sweep |
| companion pairing/devices screen | show/enter code UI |
| `docs/wire-protocol.md` | document `/v1/id` + code-bound HKDF |

## Testing

- **Crypto parity (Swift + Dart):** code-bound `pairKey`/proof produce identical
  results across platforms; wrong code → proof fails to verify. Extend existing
  parity vectors with a fixed code.
- **Sweep (pure logic):** subnet enumeration from IP+netmask, `/24` cap, and
  `/v1/id` response parsing are unit-tested as pure functions (no live sockets).
- **`PairedDevice` persistence:** round-trips `host` incl. `nil` legacy records
  (both languages).
- **Send targeting:** union includes a paired-with-host device absent from the
  mDNS peer list; de-dup prefers live peer.
- **Live end-to-end (over adb, mDNS confirmed blocked):** host shows a code on
  one device, enter it on the other; verify (a) sweep finds the peer on `:51888`,
  (b) pairing completes on both sides with a correct code and fails with a wrong
  code, (c) a copied clip transfers using the persisted host.

## Rollout / compatibility

- Optional `host` keeps existing persisted paired-device files readable.
- Fixed port is transparent to users; mDNS records carry the stable port.
- Pairing wire shape unchanged; the code enters only the HKDF `info`, and the
  target requires an active pairing-mode code — so a peer not in pairing mode
  simply refuses, which is the intended behavior.
