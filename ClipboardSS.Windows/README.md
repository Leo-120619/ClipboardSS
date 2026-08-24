# ClipboardSS for Windows

Native WPF peer for ClipboardSS. Milestones M1–M5 are implemented: protocol parity, LAN sync/tray foundations, history dashboard, global hotkeys, paste injection, region screenshots, and offline screen-text selection.

## Direct development

Install the .NET 8 SDK, then run:

```powershell
dotnet build ClipboardSS.Windows.sln
dotnet test ClipboardSS.Windows.sln
```

The WPF app targets Windows 10 build 19041 or later. Run the `ClipboardSS.App` project from Visual Studio or start its build output directly; packaging is optional for development. Core tests also run on macOS and Linux.

The default dashboard shortcut is `Ctrl+Alt+V`. Shortcut conflicts are reported at startup and can be changed immediately in Preferences. Windows blocks paste injection into elevated applications when ClipboardSS is running normally; keep the destination app at the same privilege level.

## Capture and OCR

Screenshot capture uses a per-monitor region selector and native GDI capture. Every captured region is retained as a `Screenshot` image clip and opens a review window with selectable OCR lines. Screen Text freezes every display, recognizes per-word blocks, and supports click, Ctrl-click, Shift-click, double-click, drag selection, Ctrl+A, Enter/Ctrl+C, and Lines/Spaces joining.

OCR uses `Windows.Media.Ocr` locally. It works for both direct EXE builds and MSIX installs whenever Windows has an OCR language installed. The review window links directly to Language & region when OCR is unavailable.

## MSIX packages

Packaging produces self-contained, architecture-specific MSIX files for `x64` and `arm64` (both by default). The package identity is `ClipboardSS`; the development publisher is `CN=ClipboardSS Development`. Packaging requires the Windows SDK `MakeAppx.exe` and `SignTool.exe`.

Create a local development certificate once. The PFX and its password are intentionally ignored by Git; distribute only the `.cer` to development machines.

```powershell
$password = Read-Host 'PFX password' -AsSecureString
.\scripts\new-development-certificate.ps1 -Password $password
Import-Certificate -FilePath .\artifacts\certificates\ClipboardSS-development.cer -CertStoreLocation Cert:\CurrentUser\Root
```

Build and sign both packages:

```powershell
$password = Read-Host 'PFX password' -AsSecureString
.\scripts\package-msix.ps1 -CertificatePath .\artifacts\certificates\ClipboardSS-development.pfx -CertificatePassword $password
```

The results are `artifacts\ClipboardSS_<version>_x64.msix` and `artifacts\ClipboardSS_<version>_arm64.msix`. Install the x64 build on an x64 development machine with `Add-AppxPackage .\artifacts\ClipboardSS_1.0.0.0_x64.msix`. ARM64 packages can be inspected and signature-verified on x64, but require an ARM64 Windows device or runner to execute.

For a release certificate, supply the external PFX and make its certificate subject exactly match the explicit publisher:

```powershell
$password = Read-Host 'Release PFX password' -AsSecureString
.\scripts\package-msix.ps1 -Version 1.2.3.0 -Publisher 'CN=Example Publisher' `
  -CertificatePath C:\secure\ClipboardSS-release.pfx -CertificatePassword $password
```

MSIX builds use the package startup task. Direct EXE builds retain the current-user Run-key entry. In either form, ClipboardSS persists the state Windows actually grants; if Windows denies startup permission, the Preferences checkbox reflects that result and explains how to change it.

## LAN sync and firewall

ClipboardSS listens on TCP port `51888`. Accept the Windows Defender Firewall prompt on first launch for Private networks. If the prompt was dismissed, run this once from an elevated PowerShell:

```powershell
New-NetFirewallRule -DisplayName "ClipboardSS LAN Sync" -Direction Inbound -Protocol TCP -LocalPort 51888 -Action Allow -Profile Private
```

Do not run the Flutter Windows companion at the same time; both apps bind port `51888`.

Clipboard data is protected by the paired-device ChaCha20-Poly1305 envelope. Discovery uses Windows DNS-SD where available and always falls back to a local `/24` subnet sweep during pairing.
