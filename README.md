# ClipboardSS

[![OS Support](https://img.shields.io/badge/OS-macOS%2013.0%2B-blue?style=flat-square)](https://developer.apple.com/macos/)
[![Swift Version](https://img.shields.io/badge/Swift-5.9%2B-orange?style=flat-square)](https://swift.org)
[![License](https://img.shields.io/badge/License-MIT-green?style=flat-square)](LICENSE)
[![GitHub Sponsors](https://img.shields.io/badge/Sponsor-GitHub-ea4aaa?style=flat-square&logo=github-sponsors)](https://github.com/sponsors/Leo-120619)
[![Buy Me A Coffee](https://img.shields.io/badge/Donate-Buy%20Me%20A%20Coffee-ffdd00?style=flat-square&logo=buy-me-a-coffee&logoColor=black)](https://www.buymeacoffee.com/Leo120619)

A native macOS clipboard history manager that stores text and images, performs local Optical Character Recognition (OCR), captures custom screen text regions, and provides a built-in image annotation canvas.

---

## Features

### 1. Visual Clipboard History
Saves and presents clipboard items as clean, structured cards. Text items show content previews, and copied images show scaling thumbnails.
- **Search & Filters**: Perform fuzzy text searches across saved clips and filter history by type (Text, Images, Pinned).
- **Auto-Cleanup**: Pin important clips to save them indefinitely. Unpinned items are automatically deleted after 7 days.
- **Copy & Paste**: Single-click a card to copy the content back to your active pasteboard. Double-click to paste the item directly into your active application.

![Visual Clipboard Dashboard](Assets/dashboard_preview.png)

### 2. Screen Text Selector (Drag-to-OCR)
Extract text instantly from any part of your display. 
- Triggering the selection shortcut dims the screen and opens an interactive drag-selection overlay.
- Selecting a region initiates local Vision-based character extraction.
- The parsed text is copied directly to the system clipboard, and a status HUD displays OCR statistics (word/character count) at the bottom of the screen.

![Screen Text Selector](Assets/ocr_preview.png)

### 3. Integrated Image Annotation Editor
Modify and annotate captured screenshots or copied clipboard images using a built-in canvas editor.
- **Vector Annotations**: Paint freehand with adjustable brush sizes and opacities, draw straight lines, rectangles, ellipses, and arrows, and add text overlays.
- **Image Filters**: Apply grayscale, sepia, invert, and blur operations directly from the side properties panel.
- **Canvas Operations**: Crop, rotate, flip, and scale canvas regions before saving.
- **Quick Save**: Commit edits back to your history store and copy the output directly to your clipboard.

![Native Image Editor](Assets/editor_preview.png)

### 4. Screenshot Region Capture
Configure a global hotkey to capture screen regions. Captured images open in an interactive review window where you can click OCR text blocks to copy them or open the editor to annotate the image.

---

## Technical Stack & Privacy

- **100% Offline & Private**: All clipboard monitoring, flat-file database storage, and OCR processing occur locally on your machine. No telemetry or network requests are executed.
- **System OCR Engine**: Powered by Apple's Vision Framework (`VNRecognizeTextRequest`) for secure text recognition.
- **Modular SPM Project**: Separated into `ClipboardCore` (database and data structures) and `ClipboardSS` (UI views, overlays, window controllers, and Carbon-based hotkey listeners).

---

## Getting Started

### Requirements
- macOS 13.0 or later.
- Xcode 15.0 or later.
- Swift SDK 5.9 or later.

### Run in Development
To run the application directly from the command line:
```bash
swift run ClipboardSS
```
*Note: The default shortcut to open the clipboard window is `Control + Option + V`.*

### Compile and Install
To compile a production-ready application bundle:

1. **Build a local `.app`**:
   ```bash
   scripts/build_app.sh
   open build/ClipboardSS.app
   ```

2. **Install to `/Applications`**:
   ```bash
   scripts/build_app.sh --install
   open /Applications/ClipboardSS.app
   ```

*Note: Code signing is set to ad-hoc by default. Set the `CODESIGN_IDENTITY` environment variable before executing the build script to use a development certificate.*

---

## System Permissions Required

macOS sandboxing requires user permission for system integrations:
1. **Accessibility**: Necessary for the application to paste clips into external target text fields.
2. **Screen Recording**: Necessary for taking regional screenshots and capturing display contents for OCR analysis.

If prompts do not appear automatically, go to **System Settings > Privacy & Security > Accessibility / Screen Recording** and add `/Applications/ClipboardSS.app`.

---

## Funding & Support

If you find this utility helpful, consider supporting its development:
- **GitHub Sponsors**: [Sponsor Leo-120619](https://github.com/sponsors/Leo-120619)
- **Buy Me a Coffee**: [Buy a coffee for Leo-120619](https://www.buymeacoffee.com/Leo120619)

---

## License
Licensed under the MIT License. See [LICENSE](LICENSE) for details.
