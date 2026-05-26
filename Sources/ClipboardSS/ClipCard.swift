import ClipboardCore
import SwiftUI

struct ClipCard: View {
    let clip: ClipItem
    let isProminent: Bool
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            tappableContent
            actions
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isProminent ? Color.accentColor.opacity(0.10) : Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityAction(named: "Paste") {
            model.handleClipSingleClick(clip)
        }
    }

    private var tappableContent: some View {
        HStack(alignment: .top, spacing: 12) {
            typeIcon
            clipContent
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .gesture(cardTapGesture)
        .clipCardCoachMarkTarget(.clipContent, isProminentClip: isProminent)
    }

    private var clipContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(clip.previewText)
                    .font(isProminent ? .headline : .body)
                    .foregroundStyle(.primary)
                    .lineLimit(isProminent ? 4 : 2)
                    .multilineTextAlignment(.leading)
                Spacer()
                if clip.isPinned {
                    Image(systemName: "pin.fill")
                        .foregroundStyle(.orange)
                }
            }

            if clip.type == .image {
                ImagePreview(clip: clip, baseDirectory: model.store.storageDirectory)
            }

            Text(metadata)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var cardTapGesture: some Gesture {
        let doubleClick = TapGesture(count: 2).onEnded {
            model.handleClipDoubleClick(clip)
        }
        let singleClick = TapGesture(count: 1).onEnded {
            model.handleClipSingleClick(clip)
        }
        return doubleClick.exclusively(before: singleClick)
    }

    private var typeIcon: some View {
        Image(systemName: clip.type == .text ? "text.alignleft" : "photo")
            .frame(width: 32, height: 32)
            .background(Color.secondary.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var actions: some View {
        HStack(spacing: 6) {
            Button {
                model.paste(clip, mode: .keepClipboardOpenAfterPaste)
            } label: {
                actionIcon("arrow.turn.down.left", coachTarget: .pasteButton)
            }
            .help("Paste and keep ClipboardSS open")

            Button {
                model.copy(clip)
            } label: {
                actionIcon("doc.on.doc", coachTarget: .copyButton)
            }
            .help("Copy clip")

            if clip.type == .image {
                Button {
                    let url = clip.resolvedImageURL(baseDirectory: model.store.storageDirectory)
                    if let image = NSImage(contentsOf: url) {
                        model.startEditingImage(image, clipID: clip.id)
                    } else {
                        model.lastError = "Could not load image file to edit."
                    }
                } label: {
                    Image(systemName: "pencil")
                }
                .help("Edit image")
            }

            Button {
                model.togglePinned(clip)
            } label: {
                actionIcon(clip.isPinned ? "pin.slash" : "pin", coachTarget: .pinButton)
            }
            .help(clip.isPinned ? "Unpin clip" : "Pin clip")

            Button(role: .destructive) {
                model.delete(clip)
            } label: {
                actionIcon("trash", coachTarget: .deleteButton)
            }
            .help("Delete clip")
        }
        .buttonStyle(.borderless)
    }

    private func actionIcon(
        _ systemName: String,
        coachTarget: CoachMarkSpotlight.Target
    ) -> some View {
        Image(systemName: systemName)
            .frame(width: 28, height: 28)
            .clipCardCoachMarkTarget(coachTarget, isProminentClip: isProminent)
    }

    private var metadata: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return "\(clip.type.rawValue.capitalized) • \(formatter.localizedString(for: clip.createdAt, relativeTo: Date()))"
    }
}

private extension View {
    @ViewBuilder
    func clipCardCoachMarkTarget(
        _ target: CoachMarkSpotlight.Target,
        isProminentClip: Bool
    ) -> some View {
        if CoachMarkSpotlight.shouldRegisterClipCardTarget(target, isProminentClip: isProminentClip) {
            coachMarkTarget(target)
        } else {
            self
        }
    }
}

struct DemoClipCard: View {
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            content
            actions
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .allowsHitTesting(false)
    }

    private var content: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "text.alignleft")
                .frame(width: 32, height: 32)
                .background(Color.secondary.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 6) {
                Text("Welcome to ClipboardSS — here's what a copied clip looks like.")
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(4)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("Text · just now")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .coachMarkTarget(.clipContent)
    }

    private var actions: some View {
        HStack(spacing: 6) {
            demoActionIcon("arrow.turn.down.left", target: .pasteButton)
            demoActionIcon("doc.on.doc", target: .copyButton)
            demoActionIcon("pin", target: .pinButton)
            demoActionIcon("trash", target: .deleteButton)
        }
    }

    private func demoActionIcon(_ systemName: String, target: CoachMarkSpotlight.Target) -> some View {
        Image(systemName: systemName)
            .frame(width: 28, height: 28)
            .coachMarkTarget(target)
    }
}

private struct ImagePreview: View {
    let clip: ClipItem
    let baseDirectory: URL

    var body: some View {
        if let image = NSImage(contentsOf: clip.resolvedImageURL(baseDirectory: baseDirectory)) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxHeight: 140)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}
