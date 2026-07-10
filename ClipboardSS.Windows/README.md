# ClipboardSS for Windows

Native WPF peer for ClipboardSS. Milestones M1–M5 are implemented: protocol parity, LAN sync/tray foundations, history dashboard, global hotkeys, paste injection, region screenshots, and offline screen-text selection.

## Build

Install the .NET 8 SDK, then run:

```powershell
dotnet build ClipboardSS.Windows.sln
dotnet test ClipboardSS.Windows.sln
```

The WPF app targets Windows 10 build 19041 or later. Core tests also run on macOS and Linux.

The default dashboard shortcut is `Ctrl+Alt+V`. Shortcut conflicts are reported at startup and can be changed immediately in Preferences. Windows blocks paste injection into elevated applications when ClipboardSS is running normally; keep the destination app at the same privilege level.

## Capture and OCR

Screenshot capture uses a per-monitor region selector and native GDI capture. Every captured region is retained as a `Screenshot` image clip and opens a review window with selectable OCR lines. Screen Text freezes every display, recognizes per-word blocks, and supports click, Ctrl-click, Shift-click, double-click, drag selection, Ctrl+A, Enter/Ctrl+C, and Lines/Spaces joining.

OCR uses `Windows.Media.Ocr` locally; Microsoft requires this API to run with desktop package identity. Install and launch ClipboardSS as an MSIX package, and make sure at least one Windows OCR language is installed. The review window links directly to Language & region when OCR is unavailable.

## LAN sync and firewall

ClipboardSS listens on TCP port `51888`. Accept the Windows Defender Firewall prompt on first launch for Private networks. If the prompt was dismissed, run this once from an elevated PowerShell:

```powershell
New-NetFirewallRule -DisplayName "ClipboardSS LAN Sync" -Direction Inbound -Protocol TCP -LocalPort 51888 -Action Allow -Profile Private
```

Do not run the Flutter Windows companion at the same time; both apps bind port `51888`.

Clipboard data is protected by the paired-device ChaCha20-Poly1305 envelope. Discovery uses Windows DNS-SD where available and always falls back to a local `/24` subnet sweep during pairing.
