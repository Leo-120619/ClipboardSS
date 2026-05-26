import SwiftUI
import AppKit
import ClipboardCore

struct PhotoEditorView: View {
    let image: NSImage
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    // MARK: - Editor Tooling
    enum EditorTool: String, CaseIterable, Identifiable {
        case crop = "Crop & Straighten"
        case rotate = "Rotate & Flip"
        case annotate = "Draw & Annotate"
        
        var id: String { self.rawValue }
        
        var icon: String {
            switch self {
            case .crop: "crop.rotate"
            case .rotate: "arrow.triangle.2.circlepath"
            case .annotate: "paintbrush.pointed.fill"
            }
        }
    }

    enum BrushType: String, CaseIterable, Identifiable {
        case pencil = "Pencil"
        case brush = "Brush"
        case highlighter = "Highlighter"
        case masking = "Masking"
        case eraser = "Eraser"
        
        var id: String { self.rawValue }
        
        var icon: String {
            switch self {
            case .pencil: "pencil"
            case .brush: "paintbrush"
            case .highlighter: "highlighter"
            case .masking: "pencil.and.outline"
            case .eraser: "eraser"
            }
        }
        
        var defaultSize: CGFloat {
            switch self {
            case .pencil: 3
            case .brush: 10
            case .highlighter: 24
            case .masking: 16
            case .eraser: 20
            }
        }
        
        var defaultOpacity: Double {
            switch self {
            case .highlighter: 0.4
            case .masking: 0.5
            default: 1.0
            }
        }
    }

    enum AspectRatioPreset: String, CaseIterable, Identifiable {
        case free = "Free"
        case square = "1:1"
        case sixteenNine = "16:9"
        case fourThree = "4:3"
        case threeTwo = "3:2"
        
        var id: String { self.rawValue }
        
        func ratio() -> CGFloat? {
            switch self {
            case .free: nil
            case .square: 1.0
            case .sixteenNine: 16.0 / 9.0
            case .fourThree: 4.0 / 3.0
            case .threeTwo: 3.0 / 2.0
            }
        }
    }

    // MARK: - State Management
    struct EditingState: Equatable {
        var rotation: Double = 0 // in radians
        var straightening: Double = 0 // in radians
        var isFlippedHorizontal = false
        var isFlippedVertical = false
        var cropRectNormalized = CGRect(x: 0, y: 0, width: 1, height: 1)
        var paths: [DrawingPath] = []
    }

    @State private var currentState = EditingState()
    @State private var undoStack: [EditingState] = []
    @State private var redoStack: [EditingState] = []
    
    @State private var activeTool: EditorTool = .annotate
    @State private var selectedAspectRatio: AspectRatioPreset = .free
    
    // Brush settings
    @State private var brushType: BrushType = .brush
    @State private var brushColor: Color = .blue
    @State private var brushSize: CGFloat = BrushType.brush.defaultSize
    @State private var brushOpacity: Double = BrushType.brush.defaultOpacity
    
    // Live drawing state
    @State private var currentPoints: [CGPoint] = []
    
    // Standard color palette presets
    private let colorPresets: [Color] = [
        .red, .orange, .yellow, .green, .blue, .purple, .pink, .white, .gray, .black
    ]
    
    // Crop dragging state
    @State private var activeCropDragHandle: CropDragHandle? = nil
    @State private var dragStartCropBox: CGRect? = nil

    enum CropDragHandle {
        case topLeft, topRight, bottomLeft, bottomRight
        case top, bottom, left, right
        case body
    }

    var body: some View {
        VStack(spacing: 0) {
            headerView
            Divider()
            
            HStack(spacing: 0) {
                sidebarView
                Divider()
                
                VStack(spacing: 0) {
                    mainCanvasArea
                    Divider()
                    bottomControlBar
                }
                .background(Color.black.opacity(0.88))
            }
        }
        .frame(width: 960, height: 680)
        .preferredColorScheme(.dark)
        .onAppear {
            // Check clipboard initially
            model.refresh()
        }
    }

    // MARK: - Undo/Redo Helpers
    private func recordState() {
        if undoStack.last != currentState {
            undoStack.append(currentState)
            redoStack.removeAll()
        }
    }

    private func undo() {
        guard !undoStack.isEmpty else { return }
        let previous = undoStack.removeLast()
        redoStack.append(currentState)
        currentState = previous
    }

    private func redo() {
        guard !redoStack.isEmpty else { return }
        let next = redoStack.removeLast()
        undoStack.append(currentState)
        currentState = next
    }

    private var canUndo: Bool { !undoStack.isEmpty }
    private var canRedo: Bool { !redoStack.isEmpty }

    // MARK: - Header
    private var headerView: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Photo Editor")
                    .font(.headline.weight(.semibold))
                Text(model.editingClipID != nil ? "Editing historical clip" : "Editing clipboard image")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            // Undo / Redo
            HStack(spacing: 12) {
                Button(action: undo) {
                    Image(systemName: "arrow.uturn.backward")
                }
                .disabled(!canUndo)
                .help("Undo (Cmd+Z)")
                .keyboardShortcut("z", modifiers: .command)
                
                Button(action: redo) {
                    Image(systemName: "arrow.uturn.forward")
                }
                .disabled(!canRedo)
                .help("Redo (Shift+Cmd+Z)")
                .keyboardShortcut("z", modifiers: [.command, .shift])
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 20)
            
            Spacer()
            
            HStack(spacing: 10) {
                Button("Reset All") {
                    recordState()
                    currentState = EditingState()
                    selectedAspectRatio = .free
                }
                .buttonStyle(.bordered)
                
                Button("Cancel") {
                    dismiss()
                }
                .buttonStyle(.bordered)
                
                Button("Save & Copy") {
                    saveEditedImage()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Sidebar
    private var sidebarView: some View {
        VStack(spacing: 12) {
            ForEach(EditorTool.allCases) { tool in
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        activeTool = tool
                    }
                } label: {
                    VStack(spacing: 6) {
                        Image(systemName: tool.icon)
                            .font(.title2)
                        Text(tool.rawValue)
                            .font(.caption2)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(activeTool == tool ? Color.accentColor.opacity(0.15) : Color.clear)
                    .foregroundStyle(activeTool == tool ? Color.accentColor : Color.primary)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
            
            Spacer()
        }
        .padding(12)
        .frame(width: 90)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Canvas & Drawing Math
    private var mainCanvasArea: some View {
        GeometryReader { proxy in
            let viewSize = proxy.size
            
            if let transforms = activeTool == .crop ? getFullTransforms(imageSize: image.size, viewSize: viewSize) : getTransforms(imageSize: image.size, viewSize: viewSize) {
                
                let W = image.size.width
                let H = image.size.height
                
                // Bounding box of rotated/flipped image
                let t1 = CGAffineTransform.identity
                    .translatedBy(x: W / 2, y: H / 2)
                    .scaledBy(x: currentState.isFlippedHorizontal ? -1 : 1, y: currentState.isFlippedVertical ? -1 : 1)
                    .rotated(by: currentState.rotation)
                    .rotated(by: currentState.straightening)
                let transformedBounds = CGRect(origin: .zero, size: image.size)
                    .applying(t1.translatedBy(x: -W / 2, y: -H / 2))
                let transformedSize = transformedBounds.size
                
                ZStack {
                    // Image rendered with transform effects
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .scaleEffect(x: currentState.isFlippedHorizontal ? -1 : 1, y: currentState.isFlippedVertical ? -1 : 1)
                        .rotationEffect(.radians(currentState.rotation))
                        .rotationEffect(.radians(currentState.straightening))
                        // Apply crop clipping if not in active crop edit mode
                        .scaleEffect(
                            activeTool == .crop ? 1.0 : 1.0, // base scaling
                            anchor: .center
                        )
                    
                    // Transparent Overlay for drawing or cropping
                    if activeTool == .annotate {
                        // Drawing overlay
                        Canvas { context, size in
                            // Renders historical paths
                            for path in currentState.paths {
                                var pathSwiftUI = Path()
                                guard let first = path.points.first else { continue }
                                pathSwiftUI.move(to: first.applying(transforms.forward))
                                for point in path.points.dropFirst() {
                                    pathSwiftUI.addLine(to: point.applying(transforms.forward))
                                }
                                
                                var localContext = context
                                if path.isEraser {
                                    localContext.blendMode = .clear
                                } else {
                                    localContext.blendMode = .normal
                                }
                                localContext.stroke(
                                    pathSwiftUI,
                                    with: .color(path.color.opacity(path.opacity)),
                                    style: StrokeStyle(lineWidth: path.lineWidth * getScaleFactor(viewSize: viewSize), lineCap: .round, lineJoin: .round)
                                )
                            }
                            
                            // Render current drawing path live
                            if !currentPoints.isEmpty {
                                var pathSwiftUI = Path()
                                pathSwiftUI.move(to: currentPoints.first!.applying(transforms.forward))
                                for point in currentPoints.dropFirst() {
                                    pathSwiftUI.addLine(to: point.applying(transforms.forward))
                                }
                                
                                var localContext = context
                                if brushType == .eraser {
                                    localContext.blendMode = .clear
                                } else {
                                    localContext.blendMode = .normal
                                }
                                localContext.stroke(
                                    pathSwiftUI,
                                    with: .color(brushColor.opacity(brushOpacity)),
                                    style: StrokeStyle(lineWidth: brushSize * getScaleFactor(viewSize: viewSize), lineCap: .round, lineJoin: .round)
                                )
                            }
                        }
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    let ptView = value.location
                                    let ptImg = ptView.applying(transforms.backward)
                                    // Constraint: only draw inside the original image bounds
                                    if CGRect(origin: .zero, size: image.size).contains(ptImg) {
                                        currentPoints.append(ptImg)
                                    }
                                }
                                .onEnded { _ in
                                    if !currentPoints.isEmpty {
                                        recordState()
                                        let newPath = DrawingPath(
                                            points: currentPoints,
                                            color: brushType == .eraser ? .clear : brushColor,
                                            lineWidth: brushSize,
                                            opacity: brushType == .eraser ? 1.0 : brushOpacity,
                                            isEraser: brushType == .eraser
                                        )
                                        currentState.paths.append(newPath)
                                        currentPoints = []
                                    }
                                }
                        )
                    } else if activeTool == .crop {
                        // Crop box resizing overlay
                        let displayWidth = transformedSize.width * getFullScale(transformedSize: transformedSize, viewSize: viewSize)
                        let displayHeight = transformedSize.height * getFullScale(transformedSize: transformedSize, viewSize: viewSize)
                        let offsetX = (viewSize.width - displayWidth) / 2
                        let offsetY = (viewSize.height - displayHeight) / 2
                        
                        let cropBox = CGRect(
                            x: offsetX + currentState.cropRectNormalized.origin.x * displayWidth,
                            y: offsetY + currentState.cropRectNormalized.origin.y * displayHeight,
                            width: currentState.cropRectNormalized.width * displayWidth,
                            height: currentState.cropRectNormalized.height * displayHeight
                        )
                        
                        cropOverlay(cropBox: cropBox, container: CGRect(x: offsetX, y: offsetY, width: displayWidth, height: displayHeight))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .coordinateSpace(name: "canvas")
            } else {
                Text("Image unavailable")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(40)
    }

    private func getScaleFactor(viewSize: CGSize) -> CGFloat {
        // Find the scale factor to scale drawing lines proportionally with view zoom
        let W = image.size.width
        let H = image.size.height
        let cropW = currentState.cropRectNormalized.width * W
        let cropH = currentState.cropRectNormalized.height * H
        return min(viewSize.width / cropW, viewSize.height / cropH)
    }

    private func getFullScale(transformedSize: CGSize, viewSize: CGSize) -> CGFloat {
        min(viewSize.width / transformedSize.width, viewSize.height / transformedSize.height)
    }

    // MARK: - Crop Overlay View
    private func cropOverlay(cropBox: CGRect, container: CGRect) -> some View {
        ZStack {
            // Darkened background outside cropBox
            Path { path in
                path.addRect(container)
                path.addRect(cropBox)
            }
            .fill(Color.black.opacity(0.6), style: FillStyle(eoFill: true))
            
            // Grid lines inside cropBox
            Path { path in
                // vertical grid lines
                let dx = cropBox.width / 3
                path.move(to: CGPoint(x: cropBox.minX + dx, y: cropBox.minY))
                path.addLine(to: CGPoint(x: cropBox.minX + dx, y: cropBox.maxY))
                path.move(to: CGPoint(x: cropBox.minX + dx * 2, y: cropBox.minY))
                path.addLine(to: CGPoint(x: cropBox.minX + dx * 2, y: cropBox.maxY))
                
                // horizontal grid lines
                let dy = cropBox.height / 3
                path.move(to: CGPoint(x: cropBox.minX, y: cropBox.minY + dy))
                path.addLine(to: CGPoint(x: cropBox.maxX, y: cropBox.minY + dy))
                path.move(to: CGPoint(x: cropBox.minX, y: cropBox.minY + dy * 2))
                path.addLine(to: CGPoint(x: cropBox.maxX, y: cropBox.minY + dy * 2))
            }
            .stroke(Color.white.opacity(0.3), lineWidth: 1)
            
            // Outer white boundary line
            Rectangle()
                .stroke(Color.white, lineWidth: 1.5)
                .frame(width: cropBox.width, height: cropBox.height)
                .position(x: cropBox.midX, y: cropBox.midY)
            
            // Drag Handles
            Group {
                // Corners (TL, TR, BL, BR)
                cropHandleView(handle: .topLeft, x: cropBox.minX, y: cropBox.minY, cropBox: cropBox, container: container)
                cropHandleView(handle: .topRight, x: cropBox.maxX, y: cropBox.minY, cropBox: cropBox, container: container)
                cropHandleView(handle: .bottomLeft, x: cropBox.minX, y: cropBox.maxY, cropBox: cropBox, container: container)
                cropHandleView(handle: .bottomRight, x: cropBox.maxX, y: cropBox.maxY, cropBox: cropBox, container: container)
                
                // Edges (T, B, L, R)
                cropHandleView(handle: .top, x: cropBox.midX, y: cropBox.minY, cropBox: cropBox, container: container)
                cropHandleView(handle: .bottom, x: cropBox.midX, y: cropBox.maxY, cropBox: cropBox, container: container)
                cropHandleView(handle: .left, x: cropBox.minX, y: cropBox.midY, cropBox: cropBox, container: container)
                cropHandleView(handle: .right, x: cropBox.maxX, y: cropBox.midY, cropBox: cropBox, container: container)
            }
            
            // Center gesture to drag whole crop box
            Color.clear
                .frame(width: max(0, cropBox.width - 30), height: max(0, cropBox.height - 30))
                .position(x: cropBox.midX, y: cropBox.midY)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(coordinateSpace: .named("canvas"))
                        .onChanged { value in
                            if activeCropDragHandle == nil {
                                activeCropDragHandle = .body
                                recordState()
                                dragStartCropBox = cropBox
                            }
                            guard let startBox = dragStartCropBox else { return }
                            let translation = value.translation
                            var newBox = startBox
                            // Apply translation and constrain to container
                            newBox.origin.x = min(max(container.minX, startBox.origin.x + translation.width), container.maxX - startBox.width)
                            newBox.origin.y = min(max(container.minY, startBox.origin.y + translation.height), container.maxY - startBox.height)
                            updateNormalizedCrop(box: newBox, container: container)
                        }
                        .onEnded { _ in
                            activeCropDragHandle = nil
                            dragStartCropBox = nil
                        }
                )
        }
    }

    // Let's write a simpler, highly interactive and elegant drag handler overlay.
    // We can define the crop handles directly using standard drag gestures on small overlay boxes:
    private func cropHandleView(handle: CropDragHandle, x: CGFloat, y: CGFloat, cropBox: CGRect, container: CGRect) -> some View {
        let size: CGFloat = 26
        return Rectangle()
            .fill(Color.white)
            .frame(width: handleIsCorner(handle) ? 14 : 18, height: handleIsCorner(handle) ? 14 : 6)
            .rotationEffect(.degrees(handleRotation(handle)))
            .shadow(radius: 2)
            .background(
                Color.clear
                    .frame(width: size * 1.5, height: size * 1.5)
                    .contentShape(Rectangle())
            )
            .position(x: x, y: y)
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named("canvas"))
                    .onChanged { value in
                        if activeCropDragHandle == nil {
                            activeCropDragHandle = handle
                            recordState()
                            dragStartCropBox = cropBox
                        }
                        
                        guard let startBox = dragStartCropBox else { return }
                        var newBox = startBox
                        let touchLoc = value.location
                        
                        let minSize: CGFloat = 40
                        
                        if let ratio = selectedAspectRatio.ratio() {
                            // Aspect Ratio Locked Resizing
                            let center = CGPoint(x: startBox.midX, y: startBox.midY)
                            
                            if handleIsCorner(handle) {
                                // 1. Determine anchor and direction signs
                                let anchorX: CGFloat
                                let anchorY: CGFloat
                                let s_x: CGFloat
                                let s_y: CGFloat
                                
                                switch handle {
                                case .topLeft:
                                    anchorX = startBox.maxX
                                    anchorY = startBox.maxY
                                    s_x = -1
                                    s_y = -1
                                case .topRight:
                                    anchorX = startBox.minX
                                    anchorY = startBox.maxY
                                    s_x = 1
                                    s_y = -1
                                case .bottomLeft:
                                    anchorX = startBox.maxX
                                    anchorY = startBox.minY
                                    s_x = -1
                                    s_y = 1
                                case .bottomRight:
                                    anchorX = startBox.minX
                                    anchorY = startBox.minY
                                    s_x = 1
                                    s_y = 1
                                default:
                                    anchorX = startBox.midX
                                    anchorY = startBox.midY
                                    s_x = 0
                                    s_y = 0
                                }
                                
                                // 2. Calculate vector from anchor to touch
                                let dx = touchLoc.x - anchorX
                                let dy = touchLoc.y - anchorY
                                
                                // 3. Project touch onto the diagonal vector (s_x * ratio, s_y)
                                let dot = dx * s_x * ratio + dy * s_y
                                let len2 = ratio * ratio + 1
                                var t = dot / len2
                                
                                // 4. Determine boundaries for t based on container constraints
                                let maxTX = (s_x == 1 ? (container.maxX - anchorX) : (anchorX - container.minX)) / ratio
                                let maxTY = s_y == 1 ? (container.maxY - anchorY) : (anchorY - container.minY)
                                let maxT = min(maxTX, maxTY)
                                
                                t = min(t, maxT)
                                t = max(t, max(minSize / ratio, minSize))
                                
                                // 5. Construct newBox
                                let clampedCornerX = anchorX + t * s_x * ratio
                                let clampedCornerY = anchorY + t * s_y
                                
                                let minX = min(anchorX, clampedCornerX)
                                let maxX = max(anchorX, clampedCornerX)
                                let minY = min(anchorY, clampedCornerY)
                                let maxY = max(anchorY, clampedCornerY)
                                newBox = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
                                
                            } else {
                                // Edge handles
                                switch handle {
                                case .left:
                                    let maxWidthX = startBox.maxX - container.minX
                                    let maxWidthY = min(2 * (center.y - container.minY), 2 * (container.maxY - center.y)) * ratio
                                    let proposedWidth = startBox.maxX - touchLoc.x
                                    let clampedWidth = min(min(maxWidthX, maxWidthY), max(minSize, proposedWidth))
                                    newBox.size.width = clampedWidth
                                    newBox.origin.x = startBox.maxX - clampedWidth
                                    newBox.size.height = clampedWidth / ratio
                                    newBox.origin.y = center.y - newBox.size.height / 2
                                    
                                case .right:
                                    let maxWidthX = container.maxX - startBox.minX
                                    let maxWidthY = min(2 * (center.y - container.minY), 2 * (container.maxY - center.y)) * ratio
                                    let proposedWidth = touchLoc.x - startBox.minX
                                    let clampedWidth = min(min(maxWidthX, maxWidthY), max(minSize, proposedWidth))
                                    newBox.size.width = clampedWidth
                                    newBox.size.height = clampedWidth / ratio
                                    newBox.origin.y = center.y - newBox.size.height / 2
                                    
                                case .top:
                                    let maxHeightY = startBox.maxY - container.minY
                                    let maxHeightX = min(2 * (center.x - container.minX), 2 * (container.maxX - center.x)) / ratio
                                    let proposedHeight = startBox.maxY - touchLoc.y
                                    let clampedHeight = min(min(maxHeightX, maxHeightY), max(minSize, proposedHeight))
                                    newBox.size.height = clampedHeight
                                    newBox.origin.y = startBox.maxY - clampedHeight
                                    newBox.size.width = clampedHeight * ratio
                                    newBox.origin.x = center.x - newBox.size.width / 2
                                    
                                case .bottom:
                                    let maxHeightY = container.maxY - startBox.minY
                                    let maxHeightX = min(2 * (center.x - container.minX), 2 * (container.maxX - center.x)) / ratio
                                    let proposedHeight = touchLoc.y - startBox.minY
                                    let clampedHeight = min(min(maxHeightX, maxHeightY), max(minSize, proposedHeight))
                                    newBox.size.height = clampedHeight
                                    newBox.size.width = clampedHeight * ratio
                                    newBox.origin.x = center.x - newBox.size.width / 2
                                    
                                default:
                                    break
                                }
                            }
                        } else {
                            // Free aspect ratio resizing (clamped to container)
                            switch handle {
                            case .topLeft:
                                newBox.origin.x = max(container.minX, min(touchLoc.x, startBox.maxX - minSize))
                                newBox.origin.y = max(container.minY, min(touchLoc.y, startBox.maxY - minSize))
                                newBox.size.width = startBox.maxX - newBox.origin.x
                                newBox.size.height = startBox.maxY - newBox.origin.y
                                
                            case .topRight:
                                newBox.size.width = min(container.maxX, max(touchLoc.x, startBox.minX + minSize)) - startBox.minX
                                newBox.origin.y = max(container.minY, min(touchLoc.y, startBox.maxY - minSize))
                                newBox.size.height = startBox.maxY - newBox.origin.y
                                
                            case .bottomLeft:
                                newBox.origin.x = max(container.minX, min(touchLoc.x, startBox.maxX - minSize))
                                newBox.size.width = startBox.maxX - newBox.origin.x
                                newBox.size.height = min(container.maxY, max(touchLoc.y, startBox.minY + minSize)) - startBox.minY
                                
                            case .bottomRight:
                                newBox.size.width = min(container.maxX, max(touchLoc.x, startBox.minX + minSize)) - startBox.minX
                                newBox.size.height = min(container.maxY, max(touchLoc.y, startBox.minY + minSize)) - startBox.minY
                                
                            case .top:
                                newBox.origin.y = max(container.minY, min(touchLoc.y, startBox.maxY - minSize))
                                newBox.size.height = startBox.maxY - newBox.origin.y
                                
                            case .bottom:
                                newBox.size.height = min(container.maxY, max(touchLoc.y, startBox.minY + minSize)) - startBox.minY
                                
                            case .left:
                                newBox.origin.x = max(container.minX, min(touchLoc.x, startBox.maxX - minSize))
                                newBox.size.width = startBox.maxX - newBox.origin.x
                                
                            case .right:
                                newBox.size.width = min(container.maxX, max(touchLoc.x, startBox.minX + minSize)) - startBox.minX
                                
                            case .body:
                                break
                            }
                        }
                        
                        updateNormalizedCrop(box: newBox, container: container)
                    }
                    .onEnded { _ in
                        activeCropDragHandle = nil
                        dragStartCropBox = nil
                    }
            )
    }

    private func handleIsCorner(_ handle: CropDragHandle) -> Bool {
        return handle == .topLeft || handle == .topRight || handle == .bottomLeft || handle == .bottomRight
    }

    private func handleRotation(_ handle: CropDragHandle) -> Double {
        switch handle {
        case .left, .right: 90
        default: 0
        }
    }

    private func updateNormalizedCrop(box: CGRect, container: CGRect) {
        let normX = (box.origin.x - container.minX) / container.width
        let normY = (box.origin.y - container.minY) / container.height
        let normW = box.width / container.width
        let normH = box.height / container.height
        
        currentState.cropRectNormalized = CGRect(
            x: max(0, min(1, normX)),
            y: max(0, min(1, normY)),
            width: max(0.05, min(1 - normX, normW)),
            height: max(0.05, min(1 - normY, normH))
        )
    }

    // MARK: - bottom Control Bar
    private var bottomControlBar: some View {
        VStack(spacing: 0) {
            switch activeTool {
            case .crop:
                cropAdjustmentPanel
            case .rotate:
                rotateAdjustmentPanel
            case .annotate:
                annotateAdjustmentPanel
            }
        }
        .padding()
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Crop Panel
    private var cropAdjustmentPanel: some View {
        VStack(spacing: 12) {
            // Straighten slider
            HStack(spacing: 12) {
                Image(systemName: "slider.horizontal.3")
                Text("Straighten:")
                    .font(.subheadline)
                Slider(
                    value: Binding(
                        get: { currentState.straightening },
                        set: { val in
                            if activeCropDragHandle == nil {
                                recordState()
                            }
                            currentState.straightening = val
                        }
                    ),
                    in: -(.pi / 4)...(.pi / 4)
                )
                .frame(width: 250)
                
                Text(String(format: "%.1f°", currentState.straightening * 180 / .pi))
                    .font(.subheadline.monospacedDigit())
                    .frame(width: 50, alignment: .trailing)
                
                Button("Reset") {
                    recordState()
                    currentState.straightening = 0
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
            }
            .padding(.horizontal)
            
            Divider()
            
            // Aspect Ratio presets
            HStack(spacing: 10) {
                Text("Aspect Ratio:")
                    .font(.subheadline)
                
                ForEach(AspectRatioPreset.allCases) { preset in
                    Button(preset.rawValue) {
                        selectedAspectRatio = preset
                        applyAspectRatio(preset)
                    }
                    .buttonStyle(.bordered)
                    .tint(selectedAspectRatio == preset ? Color.accentColor : Color.secondary)
                }
            }
        }
    }

    private func applyAspectRatio(_ preset: AspectRatioPreset) {
        guard let ratio = preset.ratio() else { return }
        recordState()
        
        let current = currentState.cropRectNormalized
        let currentW = current.width
        let currentH = current.height
        let currentRatio = currentW / currentH
        
        if currentRatio > ratio {
            // wide -> shrink width
            let newW = currentH * ratio
            let delta = currentW - newW
            currentState.cropRectNormalized = CGRect(
                x: min(1 - newW, max(0, current.origin.x + delta / 2)),
                y: current.origin.y,
                width: newW,
                height: currentH
            )
        } else {
            // tall -> shrink height
            let newH = currentW / ratio
            let delta = currentH - newH
            currentState.cropRectNormalized = CGRect(
                x: current.origin.x,
                y: min(1 - newH, max(0, current.origin.y + delta / 2)),
                width: currentW,
                height: newH
            )
        }
    }

    // MARK: - Rotate Panel
    private var rotateAdjustmentPanel: some View {
        HStack(spacing: 20) {
            Button {
                recordState()
                // Rotate CCW (subtract pi/2)
                currentState.rotation -= .pi / 2
                if currentState.rotation < 0 {
                    currentState.rotation += .pi * 2
                }
            } label: {
                Label("Rotate Left", systemImage: "rotate.left")
            }
            .buttonStyle(.bordered)
            
            Button {
                recordState()
                // Rotate CW (add pi/2)
                currentState.rotation += .pi / 2
                if currentState.rotation >= .pi * 2 {
                    currentState.rotation -= .pi * 2
                }
            } label: {
                Label("Rotate Right", systemImage: "rotate.right")
            }
            .buttonStyle(.bordered)
            
            Divider().frame(height: 24)
            
            Button {
                recordState()
                currentState.isFlippedHorizontal.toggle()
            } label: {
                Label("Flip Horizontally", systemImage: "arrow.left.and.right.righttriangle.left.and.righttriangle.right")
            }
            .buttonStyle(.bordered)
            .tint(currentState.isFlippedHorizontal ? Color.accentColor : Color.secondary)
            
            Button {
                recordState()
                currentState.isFlippedVertical.toggle()
            } label: {
                Label("Flip Vertically", systemImage: "arrow.up.and.down.righttriangle.up.and.righttriangle.down")
            }
            .buttonStyle(.bordered)
            .tint(currentState.isFlippedVertical ? Color.accentColor : Color.secondary)
        }
    }

    // MARK: - Annotate Panel
    private var annotateAdjustmentPanel: some View {
        VStack(spacing: 12) {
            HStack(spacing: 14) {
                // Brush Selector
                ForEach(BrushType.allCases) { type in
                    Button {
                        brushType = type
                        brushSize = type.defaultSize
                        brushOpacity = type.defaultOpacity
                        if type == .masking {
                            brushColor = .red
                        } else if type == .highlighter {
                            brushColor = .yellow
                        }
                    } label: {
                        Label(type.rawValue, systemImage: type.icon)
                    }
                    .buttonStyle(.bordered)
                    .tint(brushType == type ? Color.accentColor : Color.secondary)
                }
                
                Spacer()
                
                Button("Clear Canvas") {
                    recordState()
                    currentState.paths.removeAll()
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.red)
            }
            .padding(.horizontal)
            
            Divider()
            
            HStack(spacing: 20) {
                // Brush Size
                HStack(spacing: 10) {
                    Text("Size:")
                        .font(.subheadline)
                    Slider(value: $brushSize, in: 1...50)
                        .frame(width: 150)
                    Text("\(Int(brushSize)) px")
                        .font(.subheadline.monospacedDigit())
                        .frame(width: 50, alignment: .trailing)
                }
                
                if brushType != .eraser {
                    Divider().frame(height: 24)
                    
                    // Brush Opacity
                    HStack(spacing: 10) {
                        Text("Opacity:")
                            .font(.subheadline)
                        Slider(value: $brushOpacity, in: 0.1...1.0)
                            .frame(width: 120)
                        Text("\(Int(brushOpacity * 100))%")
                            .font(.subheadline.monospacedDigit())
                            .frame(width: 45, alignment: .trailing)
                    }
                }
                
                if brushType != .eraser && brushType != .masking {
                    Divider().frame(height: 24)
                    
                    // Color Grid
                    HStack(spacing: 6) {
                        ForEach(colorPresets, id: \.self) { color in
                            Button {
                                brushColor = color
                            } label: {
                                Circle()
                                    .fill(color)
                                    .frame(width: 20, height: 20)
                                    .overlay(
                                        Circle()
                                            .stroke(brushColor == color ? Color.white : Color.clear, lineWidth: 2)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                        
                        ColorPicker("", selection: $brushColor)
                            .labelsHidden()
                            .frame(width: 24, height: 24)
                    }
                }
            }
            .padding(.horizontal)
        }
    }

    // MARK: - Save Logic
    private func saveEditedImage() {
        guard let rendered = renderFinal() else {
            model.lastError = "Failed to render final edited image."
            return
        }
        
        model.saveEditedImage(rendered)
        dismiss()
    }

    private func renderFinal() -> NSImage? {
        let originalSize = image.size
        
        // Calculate transformed sizes
        let W = originalSize.width
        let H = originalSize.height
        
        var t1 = CGAffineTransform.identity
        t1 = t1.translatedBy(x: W / 2, y: H / 2)
        t1 = t1.scaledBy(x: currentState.isFlippedHorizontal ? -1 : 1, y: currentState.isFlippedVertical ? -1 : 1)
        t1 = t1.rotated(by: currentState.rotation)
        t1 = t1.rotated(by: currentState.straightening)
        
        let transformedBounds = CGRect(origin: .zero, size: originalSize)
            .applying(t1.translatedBy(x: -W / 2, y: -H / 2))
        let transformedSize = transformedBounds.size
        
        let cropRect = CGRect(
            x: currentState.cropRectNormalized.origin.x * transformedSize.width,
            y: currentState.cropRectNormalized.origin.y * transformedSize.height,
            width: currentState.cropRectNormalized.width * transformedSize.width,
            height: currentState.cropRectNormalized.height * transformedSize.height
        )
        
        let targetSize = cropRect.size
        guard targetSize.width > 0, targetSize.height > 0 else { return nil }
        
        // Use standard CGBitmapContext for raw pixel manipulation.
        // This avoids all coordinate system tracking and double-flipping bugs associated with AppKit NSImage.lockFocus() coordinate magic.
        let width = Int(targetSize.width)
        let height = Int(targetSize.height)
        
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        
        // Clear background
        context.setFillColor(CGColor.clear)
        context.fill(CGRect(origin: .zero, size: targetSize))
        
        // Flip graphics context to Y-down to align with drawing/SwiftUI space
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        
        // Construct finalTransform in Y-down space
        var finalT1 = CGAffineTransform.identity
        finalT1 = finalT1.translatedBy(x: W / 2, y: H / 2)
        finalT1 = finalT1.scaledBy(x: currentState.isFlippedHorizontal ? -1 : 1, y: currentState.isFlippedVertical ? -1 : 1)
        finalT1 = finalT1.rotated(by: currentState.rotation)
        finalT1 = finalT1.rotated(by: currentState.straightening)
        
        let finalTransformedBounds = CGRect(origin: .zero, size: originalSize)
            .applying(finalT1.translatedBy(x: -W / 2, y: -H / 2))
        
        let shiftToZero = CGAffineTransform(translationX: -finalTransformedBounds.minX, y: -finalTransformedBounds.minY)
        finalT1 = finalT1.translatedBy(x: -W / 2, y: -H / 2).concatenating(shiftToZero)
        
        let finalT2 = CGAffineTransform(translationX: -cropRect.minX, y: -cropRect.minY)
        let finalTransform = finalT1.concatenating(finalT2)
        
        // 1. Draw transformed image in Y-down context
        context.saveGState()
        context.concatenate(finalTransform)
        if let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            context.draw(cgImage, in: CGRect(origin: .zero, size: originalSize))
        }
        context.restoreGState()
        
        // 2. Draw vector paths in a separate transparency layer to support erasers
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        
        for path in currentState.paths {
            context.saveGState()
            if path.isEraser {
                context.setBlendMode(.clear)
            } else {
                context.setBlendMode(.normal)
            }
            
            context.concatenate(finalTransform)
            
            context.setStrokeColor(NSColor(path.color).cgColor)
            context.setAlpha(path.opacity)
            context.setLineWidth(path.lineWidth)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            
            if let first = path.points.first {
                context.beginPath()
                context.move(to: first)
                for pt in path.points.dropFirst() {
                    context.addLine(to: pt)
                }
                context.strokePath()
            }
            context.restoreGState()
        }
        
        context.endTransparencyLayer()
        
        guard let finalCgImage = context.makeImage() else { return nil }
        return NSImage(cgImage: finalCgImage, size: targetSize)
    }

    // MARK: - Transform Resolvers
    private func getTransforms(imageSize: CGSize, viewSize: CGSize) -> (forward: CGAffineTransform, backward: CGAffineTransform)? {
        let W = imageSize.width
        let H = imageSize.height
        guard W > 0, H > 0, viewSize.width > 0, viewSize.height > 0 else { return nil }
        
        var t1 = CGAffineTransform.identity
        t1 = t1.translatedBy(x: W / 2, y: H / 2)
        t1 = t1.scaledBy(x: currentState.isFlippedHorizontal ? -1 : 1, y: currentState.isFlippedVertical ? -1 : 1)
        t1 = t1.rotated(by: currentState.rotation)
        t1 = t1.rotated(by: currentState.straightening)
        
        let transformedBounds = CGRect(origin: .zero, size: imageSize)
            .applying(t1.translatedBy(x: -W / 2, y: -H / 2))
        let transformedSize = transformedBounds.size
        
        let shiftToZero = CGAffineTransform(translationX: -transformedBounds.minX, y: -transformedBounds.minY)
        t1 = t1.translatedBy(x: -W / 2, y: -H / 2).concatenating(shiftToZero)
        
        let cropRect = CGRect(
            x: currentState.cropRectNormalized.origin.x * transformedSize.width,
            y: currentState.cropRectNormalized.origin.y * transformedSize.height,
            width: currentState.cropRectNormalized.width * transformedSize.width,
            height: currentState.cropRectNormalized.height * transformedSize.height
        )
        
        let t2 = CGAffineTransform(translationX: -cropRect.minX, y: -cropRect.minY)
        
        let scale = min(viewSize.width / cropRect.width, viewSize.height / cropRect.height)
        let displayWidth = cropRect.width * scale
        let displayHeight = cropRect.height * scale
        let offsetX = (viewSize.width - displayWidth) / 2
        let offsetY = (viewSize.height - displayHeight) / 2
        
        let t3 = CGAffineTransform(translationX: offsetX, y: offsetY).scaledBy(x: scale, y: scale)
        
        let forward = t1.concatenating(t2).concatenating(t3)
        let backward = forward.inverted()
        
        return (forward, backward)
    }

    private func getFullTransforms(imageSize: CGSize, viewSize: CGSize) -> (forward: CGAffineTransform, backward: CGAffineTransform)? {
        let W = imageSize.width
        let H = imageSize.height
        guard W > 0, H > 0, viewSize.width > 0, viewSize.height > 0 else { return nil }
        
        var t1 = CGAffineTransform.identity
        t1 = t1.translatedBy(x: W / 2, y: H / 2)
        t1 = t1.scaledBy(x: currentState.isFlippedHorizontal ? -1 : 1, y: currentState.isFlippedVertical ? -1 : 1)
        t1 = t1.rotated(by: currentState.rotation)
        t1 = t1.rotated(by: currentState.straightening)
        
        let transformedBounds = CGRect(origin: .zero, size: imageSize)
            .applying(t1.translatedBy(x: -W / 2, y: -H / 2))
        let transformedSize = transformedBounds.size
        
        let shiftToZero = CGAffineTransform(translationX: -transformedBounds.minX, y: -transformedBounds.minY)
        t1 = t1.translatedBy(x: -W / 2, y: -H / 2).concatenating(shiftToZero)
        
        let scale = min(viewSize.width / transformedSize.width, viewSize.height / transformedSize.height)
        let displayWidth = transformedSize.width * scale
        let displayHeight = transformedSize.height * scale
        let offsetX = (viewSize.width - displayWidth) / 2
        let offsetY = (viewSize.height - displayHeight) / 2
        
        let t3 = CGAffineTransform(translationX: offsetX, y: offsetY).scaledBy(x: scale, y: scale)
        
        let forward = t1.concatenating(t3)
        let backward = forward.inverted()
        
        return (forward, backward)
    }
}

// MARK: - Supporting Types
struct DrawingPath: Identifiable, Equatable {
    let id = UUID()
    var points: [CGPoint]
    var color: Color
    var lineWidth: CGFloat
    var opacity: Double
    var isEraser: Bool
}
