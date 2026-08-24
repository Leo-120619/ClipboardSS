# Companion Mac Style Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restyle the Flutter companion app to match the dark macOS ClipboardSS window and logo while keeping existing behavior intact.

**Architecture:** Keep `AppState` and clip networking unchanged. Add presentation-only theme constants, local search/filter state, a mac-style home shell, and denser clip card styling inside the existing Flutter entry point.

**Tech Stack:** Flutter, Material 3, Provider, existing ClipboardSS assets.

---

## File Structure

- Modify `clipboard_companion/pubspec.yaml` to register `../Assets/clipboard.png` as a Flutter asset.
- Modify `clipboard_companion/lib/main.dart` for dark theme constants, home shell, search/filter controls, section grouping, logo widget, and clip card styling.
- Modify `clipboard_companion/test/clip_card_test.dart` to wrap tiles in the app theme and assert mac-style card behavior.

### Task 1: Register Logo Asset

**Files:**
- Modify: `clipboard_companion/pubspec.yaml`

- [ ] **Step 1: Add the ClipboardSS logo asset**

Add this under the existing `flutter:` section:

```yaml
  assets:
    - ../Assets/clipboard.png
```

- [ ] **Step 2: Verify asset registration parses**

Run: `flutter test test/clip_card_test.dart`

Expected: Tests may fail before UI changes, but Flutter should not report a pubspec asset syntax error.

### Task 2: Add Dark Mac Theme and Home Shell

**Files:**
- Modify: `clipboard_companion/lib/main.dart`

- [ ] **Step 1: Add constants and the dark theme**

Create reusable color constants and update `ClipboardCompanionApp` to use a dark theme with `themeMode: ThemeMode.dark`.

- [ ] **Step 2: Replace the standard home app bar**

Remove `AppBar(title: const Text('Clips'))` from `HomeScreen` and render a custom header in the body with the logo, `ClipboardSS`, devices, and clear actions.

- [ ] **Step 3: Add local search/filter state**

Add a text controller and enum-backed filter state to `_HomeScreenState`, dispose the controller, and derive filtered clips in the build/body path.

### Task 3: Add Search, Filters, and Sectioned List

**Files:**
- Modify: `clipboard_companion/lib/main.dart`

- [ ] **Step 1: Implement the search/filter panel**

Create a rounded dark panel containing a search field and segmented controls for All, Text, Images, and Pinned.

- [ ] **Step 2: Render latest/history sections**

When clips are available, show the first filtered clip in `LATEST` with prominent styling and the rest in `HISTORY`.

- [ ] **Step 3: Preserve empty, loading, and error states**

Keep existing empty/error/startup logic but restyle it with the dark theme and no behavior changes.

### Task 4: Restyle Clip Cards

**Files:**
- Modify: `clipboard_companion/lib/main.dart`
- Modify: `clipboard_companion/test/clip_card_test.dart`

- [ ] **Step 1: Add prominent card support**

Add an `isProminent` parameter to `ReceivedClipTile`, defaulting to `false`, and use it to choose the latest card background.

- [ ] **Step 2: Restyle card content**

Use a compact 8px card radius, 32px type icon tile, bold title text, `Text/Image - relative time` metadata, and muted right-side actions.

- [ ] **Step 3: Update widget tests**

Wrap `ReceivedClipTile` tests in `ClipboardCompanionApp`-compatible theme or a dark `MaterialApp`, pass `isProminent` where useful, and assert actions still render.

### Task 5: Verify and Debug on S25

**Files:**
- Read only unless issues are found.

- [ ] **Step 1: Format Flutter files**

Run: `dart format lib/main.dart test/clip_card_test.dart`

Expected: Formatter completes with changed or unchanged files.

- [ ] **Step 2: Run focused widget tests**

Run: `flutter test test/clip_card_test.dart`

Expected: All tests pass.

- [ ] **Step 3: Analyze Flutter app**

Run: `flutter analyze`

Expected: No new errors from the UI change.

- [ ] **Step 4: Check connected Android devices**

Run: `flutter devices`

Expected: The Samsung S25 appears as a connected Android device.

- [ ] **Step 5: Run on S25**

Run: `flutter run -d <s25-device-id>`

Expected: App installs and launches. Inspect logs for Flutter layout overflow, missing asset, or startup errors.

## Self-Review

The plan covers the approved spec: dark default theme, mac-style header, logo asset, search/filter panel, latest/history grouping, card restyling, behavior preservation, tests, and S25 debugging. No placeholder steps remain.
