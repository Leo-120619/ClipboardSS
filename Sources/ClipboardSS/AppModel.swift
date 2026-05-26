import AppKit
import ClipboardCore
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var clips: [ClipItem]
    @Published var searchText = ""
    @Published var selectedFilter: ClipFilter = .all
    @Published var lastError: String?
    @Published var isCapturingScreenshot = false
    @Published var isSelectingScreenText = false
    @Published var screenshotReview: ScreenshotReview?
    @Published var editingImage: NSImage?
    @Published var editingClipID: UUID?
    @Published var clipboardHasImage = false
    @Published var showPreferences = false
    @Published var clipboardShortcut: KeyboardShortcut
    @Published var screenshotShortcut: KeyboardShortcut?
    @Published var screenTextShortcut: KeyboardShortcut?
    @Published var launchAtLoginEnabled: Bool
    @Published var showCoachMarks: Bool
    @Published var currentCoachMarkIndex = 0

    let store: ClipStore
    nonisolated static let coachMarksCompletedDefaultsKey = "hasCompletedCoachMarks"
    nonisolated static let launchAtLoginDefaultsKey = "launchAtLoginEnabled"
    nonisolated static let coachMarkStepCount = CoachMarkStep.steps.count
    private let writer: ClipboardWriter
    private let screenshotCaptureService: ScreenshotCaptureService
    private let ocrService: OCRService
    private let screenTextCaptureService: ScreenTextCaptureService
    private let launchAtLogin: LaunchAtLoginControlling
    private let pasteboard: PasteboardClient
    var onClipboardShortcutChanged: ((KeyboardShortcut) -> Void)?
    var onScreenshotShortcutChanged: ((KeyboardShortcut?) -> Void)?
    var onScreenTextShortcutChanged: ((KeyboardShortcut?) -> Void)?
    var onPasteRequested: ((PasteRequest) -> Void)?
    var onPreferencesRequested: (() -> Void)?
    var onCloseRequested: (() -> Void)?
    var onScreenTextSelectionReady: ((ScreenTextCapture) -> Void)?

    init(
        store: ClipStore,
        writer: ClipboardWriter,
        screenshotCaptureService: ScreenshotCaptureService,
        ocrService: OCRService,
        screenTextCaptureService: ScreenTextCaptureService = ScreenTextCaptureService(),
        launchAtLogin: LaunchAtLoginControlling = LaunchAtLoginController(),
        pasteboard: PasteboardClient
    ) {
        self.store = store
        self.writer = writer
        self.screenshotCaptureService = screenshotCaptureService
        self.ocrService = ocrService
        self.screenTextCaptureService = screenTextCaptureService
        self.launchAtLogin = launchAtLogin
        self.pasteboard = pasteboard
        self.clips = store.items
        self.clipboardShortcut = .savedClipboardShortcut
        self.screenshotShortcut = .savedScreenshotShortcut
        self.screenTextShortcut = .savedScreenTextShortcut
        self.launchAtLoginEnabled = UserDefaults.standard.object(forKey: Self.launchAtLoginDefaultsKey)
            as? Bool ?? true
        let forceCoachMarks = ProcessInfo.processInfo.environment["CLIPBOARDSS_FORCE_COACH_MARKS"] == "1"
        self.showCoachMarks = forceCoachMarks || !UserDefaults.standard.bool(forKey: Self.coachMarksCompletedDefaultsKey)
        self.clipboardHasImage = pasteboard.readSnapshot().imageData != nil
        applyLaunchAtLoginPreference()
    }

    var filteredClips: [ClipItem] {
        store.clips(matching: searchText, filter: selectedFilter)
    }

    var latestClip: ClipItem? {
        clips.first
    }

    var historyClips: [ClipItem] {
        Array(filteredClips.dropFirst(filteredClips.first?.id == latestClip?.id ? 1 : 0))
    }

    func refresh() {
        clips = store.items
        clipboardHasImage = pasteboard.readSnapshot().imageData != nil
    }

    func cleanupExpiredClips() throws {
        try store.cleanupExpiredClips()
    }

    func copy(_ clip: ClipItem) {
        do {
            try writer.copy(clip)
            refresh()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func paste(_ clip: ClipItem, mode: PasteRequest) {
        do {
            try writer.copy(clip)
            refresh()
            onPasteRequested?(mode)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func handleClipSingleClick(_ clip: ClipItem) {
        paste(clip, mode: .keepClipboardOpenAfterPaste)
    }

    func handleClipDoubleClick(_ clip: ClipItem) {
        paste(clip, mode: .closeClipboardAfterPaste)
    }

    func copyText(_ text: String) {
        pasteboard.clearContents()
        pasteboard.writeText(text)
    }

    func togglePinned(_ clip: ClipItem) {
        do {
            try store.setPinned(clip.id, !clip.isPinned)
            refresh()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func delete(_ clip: ClipItem) {
        do {
            try store.delete(clip.id)
            refresh()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func captureScreenshot() {
        isCapturingScreenshot = true
        lastError = nil

        Task {
            do {
                let url = try await screenshotCaptureService.captureRegion()
                let imageData = try Data(contentsOf: url)
                _ = try store.addImageData(imageData, fileExtension: "png", previewText: "Screenshot")
                let blocks = try await ocrService.recognizeText(in: url)
                screenshotReview = ScreenshotReview(imageURL: url, selection: OCRSelectionState(blocks: blocks))
                refresh()
            } catch {
                lastError = error.localizedDescription
            }

            isCapturingScreenshot = false
        }
    }

    func startScreenTextSelection() {
        isSelectingScreenText = true
        lastError = nil

        Task {
            do {
                let capture = try await screenTextCaptureService.captureAllDisplays()
                onScreenTextSelectionReady?(capture)
            } catch {
                lastError = error.localizedDescription
            }

            isSelectingScreenText = false
        }
    }

    func setClipboardShortcut(_ shortcut: KeyboardShortcut) {
        clipboardShortcut = shortcut
        onClipboardShortcutChanged?(shortcut)
    }

    func setScreenshotShortcut(_ shortcut: KeyboardShortcut?) {
        screenshotShortcut = shortcut
        onScreenshotShortcutChanged?(shortcut)
    }

    func setScreenTextShortcut(_ shortcut: KeyboardShortcut?) {
        screenTextShortcut = shortcut
        onScreenTextShortcutChanged?(shortcut)
    }

    func setLaunchAtLoginEnabled(_ enabled: Bool) {
        launchAtLoginEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.launchAtLoginDefaultsKey)
        applyLaunchAtLoginPreference()
    }

    func requestPreferences() {
        onPreferencesRequested?()
    }

    func requestClose() {
        onCloseRequested?()
    }

    func advanceCoachMark() {
        guard showCoachMarks else { return }

        if currentCoachMarkIndex < Self.coachMarkStepCount - 1 {
            currentCoachMarkIndex += 1
        } else {
            completeCoachMarks()
        }
    }

    func previousCoachMark() {
        guard showCoachMarks else { return }
        currentCoachMarkIndex = max(currentCoachMarkIndex - 1, 0)
    }

    func completeCoachMarks() {
        currentCoachMarkIndex = 0
        showCoachMarks = false
        UserDefaults.standard.set(true, forKey: Self.coachMarksCompletedDefaultsKey)
    }

    func restartCoachMarks() {
        currentCoachMarkIndex = 0
        showCoachMarks = true
    }

    func editClipboardImage() {
        let snapshot = pasteboard.readSnapshot()
        if let data = snapshot.imageData, let image = NSImage(data: data) {
            startEditingImage(image, clipID: nil)
        } else {
            lastError = "No image found in the clipboard to edit."
        }
    }

    func startEditingImage(_ image: NSImage, clipID: UUID?) {
        self.editingClipID = clipID
        self.editingImage = image
    }

    func saveEditedImage(_ image: NSImage) {
        guard let pngData = image.pngData() else {
            lastError = "Failed to convert edited image to PNG."
            return
        }

        do {
            let clip = try store.addImageData(pngData, fileExtension: "png", previewText: "Edited Image")
            try writer.copy(clip)
            self.editingImage = nil
            self.editingClipID = nil
            refresh()
        } catch {
            lastError = "Failed to save edited image: \(error.localizedDescription)"
        }
    }

    private func applyLaunchAtLoginPreference() {
        do {
            try launchAtLogin.setEnabled(launchAtLoginEnabled)
        } catch {
            lastError = "Could not update Launch at Login: \(error.localizedDescription)"
        }
    }
}

extension NSImage {
    func pngData() -> Data? {
        guard
            let tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiffRepresentation)
        else {
            return nil
        }
        return bitmap.representation(using: .png, properties: [:])
    }
}

struct ScreenshotReview: Identifiable {
    let id = UUID()
    let imageURL: URL
    var selection: OCRSelectionState
}

enum PasteRequest: Equatable {
    case keepClipboardOpenAfterPaste
    case closeClipboardAfterPaste
}
