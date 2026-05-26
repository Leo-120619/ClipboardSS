import ClipboardCore
import SwiftUI

struct ClipboardRootView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                header
                Divider()
                ScrollViewReader { scrollProxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            if let latest = model.latestClip {
                                SectionHeader(title: "Latest")
                                    .id("latestSectionHeader")
                                ClipCard(clip: latest, isProminent: true, model: model)
                            } else if model.showCoachMarks {
                                SectionHeader(title: "Latest")
                                    .id("latestSectionHeader")
                                DemoClipCard()
                            }

                            if !model.historyClips.isEmpty {
                                SectionHeader(title: "History")
                                ForEach(model.historyClips) { clip in
                                    ClipCard(clip: clip, isProminent: false, model: model)
                                }
                            } else if model.filteredClips.isEmpty {
                                SectionHeader(title: "History")
                                EmptyStateView()
                            }
                        }
                        .padding(16)
                    }
                    .onChange(of: model.currentCoachMarkIndex) { newValue in
                        // Steps 2 to 7 (indices 1 to 6) focus on elements inside the latest clip card.
                        // Automatically scroll to the top of the scrollable list to ensure elements are fully visible.
                        if newValue >= 1 && newValue <= 6 {
                            withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) {
                                scrollProxy.scrollTo("latestSectionHeader", anchor: .top)
                            }
                        }
                    }
                }
            }
        }
        .coordinateSpace(name: CoachMarkCoordinateSpace.name)
        .overlayPreferenceValue(CoachMarkTargetPreferenceKey.self) { targets in
            GeometryReader { proxy in
                if model.showCoachMarks {
                    CoachMarkOverlay(
                        model: model,
                        targetFrames: targets.mapValues { proxy[$0] }
                    )
                }
            }
        }
        .frame(minWidth: 560, minHeight: 520)
        .sheet(item: $model.screenshotReview) { review in
            ScreenshotReviewView(review: review, model: model)
        }
        .sheet(item: Binding(
            get: { model.editingImage.map { IdentifiableImage(image: $0) } },
            set: { model.editingImage = $0?.image }
        )) { identifiableImage in
            PhotoEditorView(image: identifiableImage.image, model: model)
        }
        .sheet(isPresented: $model.showPreferences) {
            PreferencesView(model: model)
        }
        .alert("ClipboardSS", isPresented: Binding(
            get: { model.lastError != nil },
            set: { if !$0 { model.lastError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.lastError ?? "")
        }
    }

    private var header: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                HStack(spacing: 10) {
                    if let logo = ClipboardSSLogo.image(size: NSSize(width: 28, height: 28)) {
                        Image(nsImage: logo)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 28, height: 28)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    } else {
                        Image(systemName: "doc.on.clipboard")
                            .font(.title2)
                    }
                    Text("ClipboardSS")
                        .font(.title3.weight(.semibold))
                }
                .coachMarkTarget(.windowShortcut)
                Spacer()
                Button {
                    model.startScreenTextSelection()
                } label: {
                    Label(model.isSelectingScreenText ? "Scanning" : "Screen Text", systemImage: "text.viewfinder")
                }
                .disabled(model.isSelectingScreenText)
                .coachMarkTarget(.screenTextButton)
                Button {
                    model.captureScreenshot()
                } label: {
                    Label(model.isCapturingScreenshot ? "Capturing" : "Screenshot", systemImage: "camera.viewfinder")
                }
                .disabled(model.isCapturingScreenshot)
                .coachMarkTarget(.screenshotButton)
                Button {
                    model.editClipboardImage()
                } label: {
                    Label("Edit Clipboard", systemImage: "pencil")
                }
                .disabled(!model.clipboardHasImage)
                .help(model.clipboardHasImage ? "Edit current image in clipboard" : "No image in clipboard to edit")
                Button {
                    model.requestPreferences()
                } label: {
                    Image(systemName: "gearshape")
                }
                .help("Preferences")
                .accessibilityLabel("Preferences")
                .coachMarkTarget(.preferencesButton)
                Button {
                    model.requestClose()
                } label: {
                    Image(systemName: "xmark")
                }
                .help("Close ClipboardSS")
                .accessibilityLabel("Close ClipboardSS")
                .coachMarkTarget(.closeButton)
            }

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search clips", text: $model.searchText)
                    .textFieldStyle(.plain)
                Picker("Filter", selection: $model.selectedFilter) {
                    Text("All").tag(ClipFilter.all)
                    Text("Text").tag(ClipFilter.text)
                    Text("Images").tag(ClipFilter.image)
                    Text("Pinned").tag(ClipFilter.pinned)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 260)
            }
            .padding(10)
            .background(.quaternary.opacity(0.55))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .padding(16)
    }
}

private struct SectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .padding(.top, 4)
    }
}

private struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("No matching clips")
                .font(.headline)
            Text("Copy text or images anywhere on your Mac and they will appear here.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(32)
    }
}

struct IdentifiableImage: Identifiable {
    let id = UUID()
    let image: NSImage
}
