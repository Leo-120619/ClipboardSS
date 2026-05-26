import SwiftUI

struct CoachMarkOverlay: View {
    @ObservedObject var model: AppModel
    let targetFrames: [CoachMarkSpotlight.Target: CGRect]

    @State private var isGlowing = false

    private var step: CoachMarkStep {
        CoachMarkStep.steps.indices.contains(model.currentCoachMarkIndex)
            ? CoachMarkStep.steps[model.currentCoachMarkIndex]
            : CoachMarkStep.steps[0]
    }

    var body: some View {
        GeometryReader { proxy in
            let spotlightFrame = CoachMarkSpotlight.frame(
                for: step.spotlightTarget,
                in: proxy.size,
                resolvedTargets: targetFrames,
                padding: step.spotlightPadding
            )

            ZStack(alignment: .topLeading) {
                spotlightScrim(spotlightFrame: spotlightFrame, shape: step.shape)
                    .animation(.spring(response: 0.45, dampingFraction: 0.78), value: spotlightFrame)

                if let spotlightFrame {
                    spotlightRing(spotlightFrame: spotlightFrame, shape: step.shape)
                        .animation(.spring(response: 0.45, dampingFraction: 0.78), value: spotlightFrame)
                }

                cardPlacement(spotlightFrame: spotlightFrame, containerSize: proxy.size)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .animation(.spring(response: 0.45, dampingFraction: 0.78), value: model.currentCoachMarkIndex)
            }
        }
        .ignoresSafeArea()
        .transition(.opacity)
        .accessibilityElement(children: .contain)
        .onAppear {
            withAnimation(
                .easeInOut(duration: 1.6)
                .repeatForever(autoreverses: true)
            ) {
                isGlowing = true
            }
        }
    }

    @ViewBuilder
    private func spotlightScrim(spotlightFrame: CGRect?, shape: SpotlightShape) -> some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
            Color.black.opacity(0.32)
        }
        .mask {
            ScrimWithHole(spotlightFrame: spotlightFrame, spotlightShape: shape)
                .fill(style: FillStyle(eoFill: true))
        }
    }

    private func spotlightRing(spotlightFrame: CGRect, shape: SpotlightShape) -> some View {
        spotlightShapeView(shape: shape, stroke: Color.white.opacity(0.95), lineWidth: 2)
            .background {
                spotlightShapeView(
                    shape: shape,
                    stroke: LinearGradient(
                        colors: [Color.accentColor, Color.purple],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: isGlowing ? 5 : 3
                )
                .blur(radius: isGlowing ? 8 : 4)
                .opacity(isGlowing ? 0.95 : 0.6)
            }
            .frame(width: spotlightFrame.width, height: spotlightFrame.height)
            .position(x: spotlightFrame.midX, y: spotlightFrame.midY)
            .allowsHitTesting(false)
    }

    @ViewBuilder
    private func spotlightShapeView(shape: SpotlightShape) -> some View {
        switch shape {
        case .circle:
            Circle()
        case .roundedRect(let cornerRadius):
            RoundedRectangle(cornerRadius: cornerRadius)
        }
    }

    @ViewBuilder
    private func spotlightShapeView<S: ShapeStyle>(
        shape: SpotlightShape,
        stroke: S,
        lineWidth: CGFloat
    ) -> some View {
        switch shape {
        case .circle:
            Circle().stroke(stroke, lineWidth: lineWidth)
        case .roundedRect(let cornerRadius):
            RoundedRectangle(cornerRadius: cornerRadius).stroke(stroke, lineWidth: lineWidth)
        }
    }

    @ViewBuilder
    private func cardPlacement(spotlightFrame: CGRect?, containerSize: CGSize) -> some View {
        let cardWidth = min(380, max(280, containerSize.width - 32))

        if let spotlightFrame {
            let isTopHalf = spotlightFrame.midY <= containerSize.height / 2

            VStack(spacing: 0) {
                if isTopHalf {
                    Spacer()
                        .frame(height: spotlightFrame.maxY + 16)
                    coachMarkCard
                        .frame(width: cardWidth)
                    Spacer(minLength: 16)
                } else {
                    Spacer(minLength: 16)
                    coachMarkCard
                        .frame(width: cardWidth)
                    Spacer()
                        .frame(height: (containerSize.height - spotlightFrame.minY) + 16)
                }
            }
            .frame(maxWidth: .infinity)
        } else {
            VStack {
                Spacer()
                coachMarkCard
                    .frame(width: cardWidth)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var coachMarkCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: step.systemImage)
                    .font(.system(.title3, design: .rounded, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 42, height: 42)
                    .background(
                        LinearGradient(
                            colors: [Color.accentColor, Color.accentColor.opacity(0.85), Color.purple.opacity(0.8)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .shadow(color: Color.accentColor.opacity(0.3), radius: 6, x: 0, y: 3)

                VStack(alignment: .leading, spacing: 4) {
                    Text(step.title)
                        .font(.system(.headline, design: .rounded, weight: .bold))
                        .foregroundStyle(.primary)
                    Text(step.message)
                        .font(.system(.subheadline, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            pillProgressIndicator

            HStack {
                Button("Skip") {
                    model.completeCoachMarks()
                }
                .buttonStyle(SecondaryPremiumButtonStyle())

                Spacer()

                Button("Back") {
                    model.previousCoachMark()
                }
                .buttonStyle(SecondaryPremiumButtonStyle(isDisabled: model.currentCoachMarkIndex == 0))
                .disabled(model.currentCoachMarkIndex == 0)

                Button(model.currentCoachMarkIndex == CoachMarkStep.steps.count - 1 ? "Done" : "Next") {
                    model.advanceCoachMark()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(PremiumButtonStyle())
            }
        }
        .padding(18)
        .frame(minWidth: 280, idealWidth: 380, maxWidth: 380)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 20)
                    .fill(Color(nsColor: .windowBackgroundColor).opacity(0.4))
                RoundedRectangle(cornerRadius: 20)
                    .fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: 20)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.accentColor.opacity(0.05),
                                Color.purple.opacity(0.06),
                                Color.clear
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
        )
        .overlay {
            RoundedRectangle(cornerRadius: 20)
                .stroke(
                    LinearGradient(
                        colors: [.white.opacity(0.24), .white.opacity(0.06), .black.opacity(0.12)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1.5
                )
        }
        .shadow(color: .black.opacity(0.16), radius: 24, x: 0, y: 12)
        .shadow(color: Color.accentColor.opacity(0.06), radius: 40, x: 0, y: 20)
    }

    private var pillProgressIndicator: some View {
        HStack(spacing: 6) {
            ForEach(0..<CoachMarkStep.steps.count, id: \.self) { index in
                Capsule()
                    .fill(
                        index == model.currentCoachMarkIndex
                            ? LinearGradient(
                                colors: [Color.accentColor, Color.purple],
                                startPoint: .leading,
                                endPoint: .trailing
                              )
                            : LinearGradient(
                                colors: [Color.secondary.opacity(0.24), Color.secondary.opacity(0.16)],
                                startPoint: .leading,
                                endPoint: .trailing
                              )
                    )
                    .frame(width: index == model.currentCoachMarkIndex ? 18 : 6, height: 6)
                    .animation(.spring(response: 0.3, dampingFraction: 0.7), value: model.currentCoachMarkIndex)
            }
        }
        .padding(.vertical, 4)
    }
}

struct PremiumButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.body, design: .rounded, weight: .semibold))
            .padding(.vertical, 6)
            .padding(.horizontal, 16)
            .background(
                LinearGradient(
                    colors: [Color.accentColor, Color.accentColor.opacity(0.85), Color.purple.opacity(0.8)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .foregroundStyle(.white)
            .clipShape(Capsule())
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .shadow(
                color: Color.accentColor.opacity(0.25),
                radius: configuration.isPressed ? 2 : 4,
                x: 0,
                y: configuration.isPressed ? 1 : 2
            )
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

struct SecondaryPremiumButtonStyle: ButtonStyle {
    var isDisabled: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.body, design: .rounded, weight: .medium))
            .padding(.vertical, 6)
            .padding(.horizontal, 12)
            .background(
                Color.primary.opacity(
                    isDisabled ? 0.01 : (configuration.isPressed ? 0.10 : 0.04)
                )
            )
            .foregroundStyle(
                isDisabled
                    ? Color.secondary.opacity(0.35)
                    : Color.primary.opacity(0.85)
            )
            .clipShape(Capsule())
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

enum SpotlightShape: Equatable {
    case circle
    case roundedRect(cornerRadius: CGFloat)
}

struct ScrimWithHole: Shape {
    let spotlightFrame: CGRect?
    let spotlightShape: SpotlightShape

    func path(in rect: CGRect) -> Path {
        var path = Path(rect)
        if let frame = spotlightFrame {
            switch spotlightShape {
            case .circle:
                path.addEllipse(in: frame)
            case .roundedRect(let cornerRadius):
                path.addRoundedRect(
                    in: frame,
                    cornerSize: CGSize(width: cornerRadius, height: cornerRadius)
                )
            }
        }
        return path
    }
}

struct CoachMarkStep {
    let title: String
    let message: String
    let systemImage: String
    let spotlightTarget: CoachMarkSpotlight.Target
    let shape: SpotlightShape
    let spotlightPadding: CGFloat

    static let steps: [CoachMarkStep] = [
        CoachMarkStep(
            title: "Open ClipboardSS quickly",
            message: "Use Control-Option-V or the menu bar icon to bring this clipboard window forward from anywhere on your Mac.",
            systemImage: "keyboard",
            spotlightTarget: .windowShortcut,
            shape: .roundedRect(cornerRadius: 12),
            spotlightPadding: 8
        ),
        CoachMarkStep(
            title: "Single-click to paste",
            message: "Click a clip once to paste it into the previous app. ClipboardSS comes back afterward so you can keep working through your history.",
            systemImage: "cursorarrow.click",
            spotlightTarget: .clipContent,
            shape: .roundedRect(cornerRadius: 8),
            spotlightPadding: 8
        ),
        CoachMarkStep(
            title: "Double-click to paste and close",
            message: "Double-click a clip when you want to paste once and exit the clipboard window immediately.",
            systemImage: "cursorarrow.click.2",
            spotlightTarget: .clipContent,
            shape: .roundedRect(cornerRadius: 8),
            spotlightPadding: 8
        ),
        CoachMarkStep(
            title: "Paste and stay open",
            message: "Use this paste button for the same keep-open behavior when you prefer a precise button action.",
            systemImage: "arrow.turn.down.left",
            spotlightTarget: .pasteButton,
            shape: .circle,
            spotlightPadding: 12
        ),
        CoachMarkStep(
            title: "Copy without pasting",
            message: "Copy puts this clip back on the system clipboard without sending a paste command to another app.",
            systemImage: "doc.on.doc",
            spotlightTarget: .copyButton,
            shape: .circle,
            spotlightPadding: 12
        ),
        CoachMarkStep(
            title: "Pin important clips",
            message: "Pin keeps a clip from being removed by automatic cleanup. Unpin it when you no longer need it saved.",
            systemImage: "pin",
            spotlightTarget: .pinButton,
            shape: .circle,
            spotlightPadding: 12
        ),
        CoachMarkStep(
            title: "Delete old clips",
            message: "Delete removes a clip from history when it is no longer useful.",
            systemImage: "trash",
            spotlightTarget: .deleteButton,
            shape: .circle,
            spotlightPadding: 12
        ),
        CoachMarkStep(
            title: "Select visible screen text",
            message: "Screen Text lets you select text that is visible on your display, then copy the recognized text.",
            systemImage: "text.viewfinder",
            spotlightTarget: .screenTextButton,
            shape: .roundedRect(cornerRadius: 10),
            spotlightPadding: 8
        ),
        CoachMarkStep(
            title: "Capture screenshots",
            message: "Screenshot captures an area, saves it in history, and opens recognized text so you can copy only what you need.",
            systemImage: "camera.viewfinder",
            spotlightTarget: .screenshotButton,
            shape: .roundedRect(cornerRadius: 10),
            spotlightPadding: 8
        ),
        CoachMarkStep(
            title: "Tune shortcuts and permissions",
            message: "Open Preferences to change shortcuts, grant permissions, and replay this tour later.",
            systemImage: "gearshape",
            spotlightTarget: .preferencesButton,
            shape: .circle,
            spotlightPadding: 10
        ),
        CoachMarkStep(
            title: "Exit the clipboard",
            message: "Use Close or press Escape to hide ClipboardSS. Your clips keep saving in the background.",
            systemImage: "xmark",
            spotlightTarget: .closeButton,
            shape: .circle,
            spotlightPadding: 10
        )
    ]
}

enum CoachMarkSpotlight {
    enum Target: CaseIterable {
        case windowShortcut
        case clipList
        case clipContent
        case pasteButton
        case copyButton
        case pinButton
        case deleteButton
        case screenTextButton
        case screenshotButton
        case preferencesButton
        case closeButton
    }

    static let resolvedTargetPadding: CGFloat = 8

    static func isScrollableTarget(_ target: Target) -> Bool {
        switch target {
        case .clipContent, .pasteButton, .copyButton, .pinButton, .deleteButton:
            return true
        default:
            return false
        }
    }

    static func shouldRegisterClipCardTarget(
        _ target: Target,
        isProminentClip: Bool
    ) -> Bool {
        isProminentClip && isScrollableTarget(target)
    }

    static func frame(
        for target: Target,
        in size: CGSize,
        resolvedTargets: [Target: CGRect] = [:],
        padding: CGFloat = resolvedTargetPadding
    ) -> CGRect? {
        guard let resolvedFrame = resolvedTargets[target] else { return nil }
        let paddedFrame = resolvedFrame.insetBy(dx: -padding, dy: -padding)
        return clamp(paddedFrame, to: size)
    }

    private static func clamp(_ frame: CGRect, to size: CGSize) -> CGRect {
        let minSide: CGFloat = 24
        let width = min(max(frame.width, minSide), max(size.width, minSide))
        let height = min(max(frame.height, minSide), max(size.height, minSide))
        let maxX = max(size.width - width, 0)
        let maxY = max(size.height - height, 0)
        let x = min(max(frame.midX - width / 2, 0), maxX)
        let y = min(max(frame.midY - height / 2, 0), maxY)
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

enum CoachMarkCoordinateSpace {
    static let name = "ClipboardSSCoachMarkCoordinateSpace"
}

struct CoachMarkTargetPreferenceKey: PreferenceKey {
    static let defaultValue: [CoachMarkSpotlight.Target: Anchor<CGRect>] = [:]

    static func reduce(
        value: inout [CoachMarkSpotlight.Target: Anchor<CGRect>],
        nextValue: () -> [CoachMarkSpotlight.Target: Anchor<CGRect>]
    ) {
        for (target, anchor) in nextValue() where value[target] == nil {
            value[target] = anchor
        }
    }
}

extension View {
    func coachMarkTarget(_ target: CoachMarkSpotlight.Target) -> some View {
        anchorPreference(key: CoachMarkTargetPreferenceKey.self, value: .bounds) { anchor in
            [target: anchor]
        }
    }
}
