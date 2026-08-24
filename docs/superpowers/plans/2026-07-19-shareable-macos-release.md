# Shareable macOS Release Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make ClipboardSS release builds fail closed without trusted signing, optionally notarize/staple a DMG, and document a safe sharing workflow.

**Architecture:** Keep the existing XcodeGen + manual inside-out signing flow, but separate local development builds from release packaging. The release script will require a Developer ID identity, validate the app with `codesign` and `spctl`, optionally submit to Apple notarization, staple the ticket, and validate the final DMG workflow. No application source code changes are needed.

**Tech Stack:** Bash, XcodeGen, xcodebuild, codesign, spctl, hdiutil, xcrun notarytool, xcrun stapler.

## Global Constraints

- Preserve unrelated working-tree changes.
- Do not embed Apple credentials in repository files.
- Never call a local/ad-hoc signature a shareable release.
- Sign the embedded ShareExtension.appex before signing ClipboardSS.app.
- Require hardened runtime for release signing.
- Keep temporary staging directories cleaned up on exit.

---

### Task 1: Add a fail-closed release build script

**Files:**
- Create: `scripts/release.sh`
- Modify: `scripts/build_app.sh` only if needed to expose a reusable signing contract

**Interfaces:**
- Consumes: `CODESIGN_IDENTITY`, `APPLE_ID`, `APPLE_TEAM_ID`, and `NOTARY_PROFILE` environment variables.
- Produces: `build/ClipboardSS.dmg` and a notarized/stapled `build/ClipboardSS.app` when notarization is enabled.

- [ ] **Step 1: Define strict CLI modes**
  - Support `--notarize` and `--no-notarize`; default to `--no-notarize` only for developer testing, while the shareable release path requires `--notarize`.
  - Reject unknown arguments with exit status 64.
  - Require `CODESIGN_IDENTITY` to contain `Developer ID Application:`; do not fall back to a local or ad-hoc identity.

- [ ] **Step 2: Build and sign the app**
  - Run the existing XcodeGen/xcodebuild build.
  - Sign `Contents/PlugIns/ShareExtension.appex` first and `ClipboardSS.app` second with `--options runtime`, `--timestamp`, and `ClipboardSS.entitlements` / `ShareExtension.entitlements`.
  - Verify with `codesign --verify --deep --strict --verbose=2`.

- [ ] **Step 3: Validate Gatekeeper acceptance**
  - Run `spctl --assess --type execute --verbose=4` on the signed app.
  - Stop with a clear error if assessment fails; do not create a shareable DMG from an unaccepted app.

- [ ] **Step 4: Create the DMG**
  - Use a temporary staging directory containing the app and an Applications symlink.
  - Generate `build/ClipboardSS.dmg` with `hdiutil create -format UDZO`.
  - Remove any prior output only after validating the target path is exactly under `build/`.

- [ ] **Step 5: Add notarization and stapling**
  - Submit the DMG with `xcrun notarytool submit --wait --keychain-profile "$NOTARY_PROFILE"`.
  - Run `xcrun stapler staple` on the app and DMG, then validate with `xcrun stapler validate`.
  - Re-run `spctl --assess --type open --context context:primary-signature --verbose=4` on the final DMG.

- [ ] **Step 6: Run shell syntax validation**
  - Run `bash -n scripts/release.sh`.
  - Expected: exit status 0.

---

### Task 2: Document certificate and notarization setup

**Files:**
- Modify: `README.md`

**Interfaces:**
- Consumes: the exact environment variables and CLI contract from `scripts/release.sh`.
- Produces: documented setup and release commands that do not expose secrets.

- [ ] **Step 1: Replace the inaccurate signing note**
  - Explain that `scripts/build_app.sh` is for local development and is not shareable.
  - Explain that sharing requires a Developer ID Application certificate and notarization.

- [ ] **Step 2: Document credential setup**
  - Show how to inspect identities with `security find-identity -v -p codesigning`.
  - Show how to store notarization credentials using `xcrun notarytool store-credentials` without putting passwords in the repo.
  - Document `CODESIGN_IDENTITY` and `NOTARY_PROFILE`.

- [ ] **Step 3: Document the release command and expected artifacts**
  - Add `CODESIGN_IDENTITY='Developer ID Application: ...' NOTARY_PROFILE='...' scripts/release.sh --notarize`.
  - State that the resulting `build/ClipboardSS.dmg` is the artifact to share.
  - Include the consumer workflow: open the DMG, drag the app to Applications, then launch it.

---

### Task 3: Verify behavior and preserve repository state

**Files:**
- Test: `scripts/release.sh` via shell-level checks

**Interfaces:**
- Consumes: current repository and local signing tool availability.
- Produces: verification evidence and no changes to unrelated files.

- [ ] **Step 1: Confirm fail-closed behavior**
  - Run `CODESIGN_IDENTITY='ClipboardSS Local Code Signing' scripts/release.sh --no-notarize`.
  - Expected: nonzero exit with an error explaining that Developer ID Application is required.

- [ ] **Step 2: Confirm syntax and repository diff**
  - Run `bash -n scripts/release.sh`.
  - Run `git diff --check`.
  - Run `git status --short` and confirm only intended release files changed.

- [ ] **Step 3: Report credential limitation**
  - If no Developer ID identity is installed, state that a real notarized artifact could not be generated in this environment.
  - Provide the exact command the user can run after installing credentials.

