# Companion Mac Style Design

## Goal

Restyle the Flutter companion app so it looks like the dark macOS ClipboardSS window by default while preserving the current sync, send, copy, preview, delete, and device pairing behavior.

## Scope

- Apply a dark default Material theme matching the macOS screenshot: charcoal background, muted gray cards, blue selected/latest state, light foreground text, and subdued icon colors.
- Replace the generic `Clips` app bar with a compact ClipboardSS header that includes the ClipboardSS logo, app name, device action, and clear action.
- Add a rounded search and filter control row similar to the macOS search bar and segmented picker.
- Split clips into `LATEST` and `HISTORY` sections, with the first clip styled as the prominent latest card.
- Restyle clip cards to match the macOS card density, corner radius, type icon, metadata, and action icons.
- Register and use the existing `Assets/clipboard.png` artwork in Flutter for the visible app logo.
- Keep implementation limited to the companion app UI and tests. Do not change network sync, clip storage, hashing, pairing, or platform channels.

## Design

The home screen becomes a custom dark scaffold rather than a standard `AppBar` layout. It uses a header stack with the ClipboardSS logo and title at the top, compact icon buttons for devices and clear-all, then a rounded search/filter panel. The list area renders the first filtered clip under `LATEST` and remaining filtered clips under `HISTORY`.

The Flutter UI keeps the existing `AppState` source of truth. Search and filter state stay local to `HomeScreen` because they are presentation-only and do not belong in sync/storage state. Filtering supports all clips, text, images, and pinned, with pinned initially behaving as an empty filter until the mobile model grows a persisted pinned flag.

Clip cards continue to expose the existing actions: resend, copy, and delete. Image clips still show previews and open the existing image preview dialog. Text clips still copy to the local clipboard on tap or copy action.

## Testing

Widget tests should verify that the companion renders the ClipboardSS identity, dark mac-style cards, latest/history grouping, image previews, and narrow-card action layout without exceptions. Existing Flutter tests remain the main regression coverage because this change is visual and state-preserving.
