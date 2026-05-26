import AppKit
import ClipboardCore
import SwiftUI

@MainActor
final class ScreenTextOverlayController {
    private var windows: [ScreenTextOverlayWindow] = []

    func present(capture: ScreenTextCapture, copyHandler: @escaping (String) -> Void) {
        dismiss()

        let model = ScreenTextOverlayModel(
            selection: ScreenTextSelectionState(blocks: capture.blocks),
            copyHandler: { [weak self] text in
                copyHandler(text)
                self?.dismiss()
            },
            cancelHandler: { [weak self] in
                self?.dismiss()
            }
        )

        for screen in NSScreen.screens {
            guard let displayID = screen.displayID else {
                continue
            }
            guard let snapshot = capture.snapshots[displayID] else {
                continue
            }

            let window = ScreenTextOverlayWindow(
                contentRect: screen.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.model = model
            window.displayID = displayID
            window.level = .screenSaver
            window.backgroundColor = .clear
            window.isOpaque = false
            window.hasShadow = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            window.ignoresMouseEvents = false
            window.contentView = NSHostingView(rootView: ScreenTextOverlayView(
                model: model,
                displayID: displayID,
                screenFrame: screen.frame,
                snapshot: NSImage(cgImage: snapshot, size: screen.frame.size)
            ))
            window.makeKeyAndOrderFront(nil)
            windows.append(window)
        }

        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func dismiss() {
        for window in windows {
            window.orderOut(nil)
        }
        windows.removeAll()
        NSCursor.arrow.set()
    }
}

@MainActor
private final class ScreenTextOverlayModel: ObservableObject {
    @Published var selection: ScreenTextSelectionState
    @Published var hoveredID: String?
    private let copyHandler: (String) -> Void
    private let cancelHandler: () -> Void

    init(
        selection: ScreenTextSelectionState,
        copyHandler: @escaping (String) -> Void,
        cancelHandler: @escaping () -> Void
    ) {
        self.selection = selection
        self.copyHandler = copyHandler
        self.cancelHandler = cancelHandler
    }

    func selectOnly(_ id: String) {
        selection.select(id)
    }

    func toggle(_ id: String) {
        selection.toggle(id)
    }

    func extend(to id: String) {
        selection.extend(to: id)
    }

    func selectLine(containing id: String) {
        selection.selectLine(containing: id)
    }

    func selectAll(displayID: UInt32) {
        selection.selectAll(displayID: displayID)
    }

    func clearSelection() {
        selection.clearSelection()
    }

    func selectRange(from start: CGPoint, to end: CGPoint) {
        selection.selectRange(from: start, to: end)
    }

    func extendRange(to end: CGPoint) {
        selection.extendRange(to: end)
    }

    func setJoinMode(_ mode: ScreenTextJoinMode) {
        selection.joinMode = mode
    }

    func copySelected() {
        guard selection.canCopySelection else {
            NSSound.beep()
            return
        }
        copyHandler(selection.selectedText)
    }

    func cancel() {
        cancelHandler()
    }
}

private final class ScreenTextOverlayWindow: NSWindow {
    weak var model: ScreenTextOverlayModel?
    var displayID: UInt32 = 0

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch event.keyCode {
        case 36, 76:
            model?.copySelected()
        case 53:
            model?.cancel()
        case 0 where mods.contains(.command):
            model?.selectAll(displayID: displayID)
        case 8 where mods.contains(.command):
            model?.copySelected()
        default:
            super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        model?.cancel()
    }
}

private struct ScreenTextOverlayView: View {
    @ObservedObject var model: ScreenTextOverlayModel
    let displayID: UInt32
    let screenFrame: CGRect
    let snapshot: NSImage
    @State private var dragAnchorPoint: CGPoint?
    @State private var dragShiftExtending = false

    private var displayBlocks: [ScreenTextBlock] {
        model.selection.blocks.filter { $0.displayID == displayID }
    }

    private var selectedDisplayBlocks: [ScreenTextBlock] {
        displayBlocks.filter { model.selection.selectedIDs.contains($0.id) }
    }

    private var hasSelectionOnDisplay: Bool {
        !selectedDisplayBlocks.isEmpty
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Image(nsImage: snapshot)
                .resizable()
                .interpolation(.high)
                .ignoresSafeArea()

            Color.black.opacity(0.04)
                .ignoresSafeArea()

            ribbonLayer

            if let hoveredID = model.hoveredID,
               !model.selection.selectedIDs.contains(hoveredID),
               let block = displayBlocks.first(where: { $0.id == hoveredID }) {
                let rect = localRect(for: block.bounds)
                Rectangle()
                    .fill(Color.accentColor.opacity(0.16))
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
                    .allowsHitTesting(false)
            }

            hitTargetLayer

            actionBar
                .padding(.bottom, 28)
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 4)
                .onChanged { value in
                    let endPoint = globalPoint(from: value.location)
                    if dragAnchorPoint == nil {
                        dragAnchorPoint = globalPoint(from: value.startLocation)
                        dragShiftExtending = NSEvent.modifierFlags.contains(.shift)
                    }
                    if dragShiftExtending {
                        model.extendRange(to: endPoint)
                    } else {
                        let start = dragAnchorPoint ?? endPoint
                        model.selectRange(from: start, to: endPoint)
                    }
                }
                .onEnded { _ in
                    dragAnchorPoint = nil
                    dragShiftExtending = false
                }
        )
    }

    @ViewBuilder
    private var ribbonLayer: some View {
        ForEach(selectionRibbons) { ribbon in
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(Color.accentColor.opacity(0.42))
                .frame(width: ribbon.frame.width, height: ribbon.frame.height)
                .position(x: ribbon.frame.midX, y: ribbon.frame.midY)
                .allowsHitTesting(false)
        }
    }

    private var hitTargetLayer: some View {
        ForEach(displayBlocks) { block in
            let rect = localRect(for: block.bounds)
            ScreenTextHitTarget(
                onHoverChange: { hovering in
                    if hovering {
                        model.hoveredID = block.id
                        NSCursor.iBeam.set()
                    } else {
                        if model.hoveredID == block.id {
                            model.hoveredID = nil
                        }
                        NSCursor.arrow.set()
                    }
                },
                onTripleTap: { model.selectLine(containing: block.id) },
                onTap: {
                    let mods = NSEvent.modifierFlags
                    if mods.contains(.command) {
                        model.toggle(block.id)
                    } else if mods.contains(.shift) {
                        model.extend(to: block.id)
                    } else {
                        model.selectOnly(block.id)
                    }
                }
            )
            .frame(width: max(rect.width, 8), height: max(rect.height, 8))
            .position(x: rect.midX, y: rect.midY)
        }
    }

    @ViewBuilder
    private var actionBar: some View {
        if hasSelectionOnDisplay {
            ScreenTextActionBar(
                selectionCount: selectedDisplayBlocks.count,
                preview: previewText,
                joinMode: Binding(
                    get: { model.selection.joinMode },
                    set: { model.setJoinMode($0) }
                ),
                onCopy: { model.copySelected() },
                onCancel: { model.cancel() },
                onClear: { model.clearSelection() }
            )
        } else {
            ScreenTextHintBar()
        }
    }

    private var selectionRibbons: [SelectionRibbon] {
        let groups = Dictionary(grouping: selectedDisplayBlocks) { $0.lineID ?? $0.id }
        return groups.compactMap { lineKey, blocks in
            guard !blocks.isEmpty else { return nil }
            let minX = blocks.map(\.bounds.minX).min() ?? 0
            let maxX = blocks.map(\.bounds.maxX).max() ?? 0
            let minY = blocks.map(\.bounds.minY).min() ?? 0
            let maxY = blocks.map(\.bounds.maxY).max() ?? 0
            let global = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
            let local = localRect(for: global).insetBy(dx: -1, dy: -1)
            return SelectionRibbon(id: lineKey, frame: local)
        }
    }

    private var previewText: String {
        let text = model.selection.selectedText
        let limit = 80
        if text.count <= limit {
            return text
        }
        let endIndex = text.index(text.startIndex, offsetBy: limit)
        return String(text[..<endIndex]) + "…"
    }

    private func localRect(for globalRect: CGRect) -> CGRect {
        CGRect(
            x: globalRect.minX - screenFrame.minX,
            y: screenFrame.maxY - globalRect.maxY,
            width: globalRect.width,
            height: globalRect.height
        )
    }

    private func globalPoint(from localPoint: CGPoint) -> CGPoint {
        CGPoint(
            x: screenFrame.minX + localPoint.x,
            y: screenFrame.maxY - localPoint.y
        )
    }
}

private struct SelectionRibbon: Identifiable {
    let id: String
    let frame: CGRect
}

private struct ScreenTextHitTarget: View {
    let onHoverChange: (Bool) -> Void
    let onTripleTap: () -> Void
    let onTap: () -> Void

    var body: some View {
        Color.white.opacity(0.001)
            .contentShape(Rectangle())
            .onHover(perform: onHoverChange)
            .onTapGesture(count: 3, perform: onTripleTap)
            .onTapGesture(count: 1, perform: onTap)
    }
}

private struct ScreenTextActionBar: View {
    let selectionCount: Int
    let preview: String
    @Binding var joinMode: ScreenTextJoinMode
    let onCopy: () -> Void
    let onCancel: () -> Void
    let onClear: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(selectionCount) \(selectionCount == 1 ? "word" : "words") · \(preview.count) chars")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.8))
                Text(preview.isEmpty ? " " : preview)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 360, alignment: .leading)
            }

            Divider()
                .frame(height: 28)
                .overlay(Color.white.opacity(0.18))

            Toggle(isOn: Binding(
                get: { joinMode == .lines },
                set: { joinMode = $0 ? .lines : .spaces }
            )) {
                Text("Lines")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white)
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .tint(.accentColor)

            Button(action: onClear) {
                Text("Clear")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.white.opacity(0.08))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)

            Button(action: onCancel) {
                Text("Cancel")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.white.opacity(0.12))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)

            Button(action: onCopy) {
                HStack(spacing: 6) {
                    Text("Copy")
                        .font(.caption.weight(.semibold))
                    Text("⏎")
                        .font(.caption2)
                        .opacity(0.85)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(Color.accentColor)
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(.black.opacity(0.78))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(.white.opacity(0.08), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.4), radius: 18, y: 6)
        )
    }
}

private struct ScreenTextHintBar: View {
    var body: some View {
        Text("Drag to select · click a word · ⇧-click extend · triple-click line · ⌘A all · ⌘⏎ copy · esc cancel")
            .font(.caption.weight(.medium))
            .foregroundStyle(.white.opacity(0.9))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(.black.opacity(0.6))
            )
    }
}
