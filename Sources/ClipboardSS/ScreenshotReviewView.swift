import ClipboardCore
import SwiftUI

struct ScreenshotReviewView: View {
    @State private var review: ScreenshotReview
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    init(review: ScreenshotReview, model: AppModel) {
        self._review = State(initialValue: review)
        self.model = model
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Screenshot Text")
                    .font(.title3.weight(.semibold))
                Spacer()
                if review.selection.canCopySelection {
                    Button {
                        model.copyText(review.selection.selectedText)
                        dismiss()
                    } label: {
                        Label("Copy Selection", systemImage: "doc.on.doc")
                    }
                    .keyboardShortcut(.defaultAction)
                }
                Button("Done") {
                    dismiss()
                }
            }
            .padding()

            Divider()

            HStack(alignment: .top, spacing: 0) {
                screenshot
                    .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
                    .padding()

                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    Text("Recognized Text")
                        .font(.headline)
                    if review.selection.blocks.isEmpty {
                        Text("No text was detected in this screenshot.")
                            .foregroundStyle(.secondary)
                    } else {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 8) {
                                ForEach(review.selection.blocks) { block in
                                    OCRBlockButton(
                                        block: block,
                                        isSelected: review.selection.selectedIDs.contains(block.id)
                                    ) {
                                        review.selection.toggle(block.id)
                                    }
                                }
                            }
                        }
                    }
                }
                .frame(width: 300)
                .padding()
            }
        }
        .frame(width: 860, height: 600)
    }

    private var screenshot: some View {
        Group {
            if let image = NSImage(contentsOf: review.imageURL) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .background(Color.black.opacity(0.04))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                Text("Screenshot unavailable")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct OCRBlockButton: View {
    let block: OCRTextBlock
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                Text(block.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .multilineTextAlignment(.leading)
            }
            .padding(10)
            .background(isSelected ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }
}
