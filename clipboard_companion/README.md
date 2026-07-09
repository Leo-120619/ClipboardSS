# Clipboard Companion

Flutter companion app for [ClipboardSS](../README.md), syncing your clipboard
across devices on the local network. Targets **Android**, **iOS**, and
**Windows**; the macOS peer is the native Swift app in the repo root.

All devices speak the same wire protocol (see
[docs/wire-protocol.md](../docs/wire-protocol.md)): HTTP over TCP port
**51888**, clips encrypted end-to-end with ChaCha20-Poly1305, pairing via a
6-digit code (X25519 + HKDF), discovery via Bonjour/mDNS
(`_clipboardss._tcp`) with a subnet-sweep fallback.

## Platform behavior

| Platform | Clipboard capture | Runs in background |
|---|---|---|
| Android / iOS | Manual (open the app, review, send) | No — sync pauses when backgrounded |
| Windows | Automatic — the app watches the clipboard and broadcasts changes | Yes — lives in the system tray |

## Windows

The Windows build is a full desktop peer like the Mac app:

- **System tray**: closing the window hides it to the tray. The tray menu
  shows the 5 most recent clips (click to copy), a *Pause sync* toggle,
  *Start at login*, and *Quit*.
- **Auto-sync**: copying text or images anywhere in Windows broadcasts them
  to paired devices; incoming clips are written straight to the Windows
  clipboard (as PNG + CF_DIB for images, so they paste into both modern apps
  and Office/Paint).

### Building

Requires a Windows 10/11 machine (or VM) with Visual Studio C++ workload:

```
flutter build windows
```

### Firewall

The app listens on TCP **51888** for incoming clips. On first launch Windows
Defender Firewall prompts to allow it — check **Private networks** and click
*Allow access*. If you dismissed the prompt, either re-enable it under
*Windows Security → Firewall & network protection → Allow an app through
firewall*, or add the rule from an elevated prompt:

```
netsh advfirewall firewall add rule name="ClipboardSS" dir=in action=allow protocol=TCP localport=51888
```

Without the rule, other devices cannot deliver clips to the PC (the PC can
still send clips out).

### Discovery notes

mDNS on Windows is best-effort (`bonsoir` uses the native Windows DNS-SD API,
Windows 10 1809+). If mDNS is blocked on your network, pairing and sync still
work: peers find each other by probing the subnet on port 51888, and paired
devices remember each other's addresses.

## Development

```
flutter pub get
flutter test      # protocol parity + desktop sync tests, run on any OS
flutter analyze
```

Protocol logic lives in `lib/core/` (pure Dart, byte-compatible with the
Swift implementation — parity is enforced by the test vectors in
`docs/wire-protocol.md`). Windows-only code lives in `lib/desktop/` and
`windows/runner/clipboard_service.cpp` (Win32 clipboard bridge over the
`clipboard_companion/win_clipboard` method channel).
