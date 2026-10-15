import CoreGraphics
import Foundation

public enum ScreenTextSource: String, Equatable, Sendable {
    case accessibility
    case ocr
}

public struct ScreenTextBlock: Equatable, Identifiable, Sendable {
    public let id: String
    public var text: String
    public var bounds: CGRect
    public var displayID: UInt32
    public var source: ScreenTextSource
    public var lineID: String?

    public init(
        id: String,
        text: String,
        bounds: CGRect,
        displayID: UInt32,
        source: ScreenTextSource,
        lineID: String? = nil
    ) {
        self.id = id
        self.text = text
        self.bounds = bounds
        self.displayID = displayID
        self.source = source
        self.lineID = lineID
    }

    public var center: CGPoint {
        CGPoint(x: bounds.midX, y: bounds.midY)
    }
}

public enum ScreenTextJoinMode: Sendable, Equatable {
    case lines
    case spaces
}

public struct ScreenTextSelectionState: Equatable, Sendable {
    public var blocks: [ScreenTextBlock]
    public private(set) var selectedIDs: Set<String>
    public private(set) var anchorID: String?
    public var joinMode: ScreenTextJoinMode
    private var regionByBlockID: [String: Int]

    public init(
        blocks: [ScreenTextBlock],
        selectedIDs: Set<String> = [],
        anchorID: String? = nil,
        joinMode: ScreenTextJoinMode = .lines
    ) {
        let prepared = Self.sortedForReading(Self.deduplicated(blocks))
        let lineAssigned = Self.assignLineIDsIfNeeded(prepared)
        self.blocks = lineAssigned
        self.selectedIDs = selectedIDs
        self.anchorID = anchorID
        self.joinMode = joinMode
        self.regionByBlockID = Self.assignTextRegions(lineAssigned)
    }

    public var canCopySelection: Bool {
        !selectedIDs.isEmpty
    }

    public var selectedText: String {
        joinedText(mode: joinMode)
    }

    public func joinedText(mode: ScreenTextJoinMode) -> String {
        let selectedBlocks = blocks.filter { selectedIDs.contains($0.id) }
        return Self.join(blocks: selectedBlocks, mode: mode)
    }

    public static func joinedText(blocks: [ScreenTextBlock], mode: ScreenTextJoinMode) -> String {
        let prepared = assignLineIDsIfNeeded(sortedForReading(deduplicated(blocks)))
        return join(blocks: prepared, mode: mode)
    }

    private static func join(blocks: [ScreenTextBlock], mode: ScreenTextJoinMode) -> String {
        guard !blocks.isEmpty else { return "" }

        switch mode {
        case .spaces:
            return blocks.map(\.text).joined(separator: " ")
        case .lines:
            var result = ""
            var previousLineID: String?
            var previousDisplayID: UInt32?
            for block in blocks {
                if let prevLine = previousLineID {
                    let sameDisplay = previousDisplayID == block.displayID
                    let sameLine = block.lineID == prevLine
                    result += (sameDisplay && sameLine) ? " " : "\n"
                }
                result += block.text
                previousLineID = block.lineID
                previousDisplayID = block.displayID
            }
            return result
        }
    }

    public mutating func toggle(_ id: String) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
            anchorID = id
        }
    }

    public mutating func select(_ id: String) {
        selectedIDs = [id]
        anchorID = id
    }

    public mutating func extend(to id: String) {
        guard let anchor = anchorID ?? selectedIDs.first else {
            select(id)
            return
        }
        guard let anchorBlock = blocks.first(where: { $0.id == anchor }),
              let requestedEndBlock = blocks.first(where: { $0.id == id })
        else {
            return
        }
        let regionBlocks = blocks(inSameRegionAs: anchorBlock)
        let endBlock = regionByBlockID[requestedEndBlock.id] == regionByBlockID[anchorBlock.id]
            ? requestedEndBlock
            : nearestBlock(to: requestedEndBlock.center, among: regionBlocks)
        guard let endBlock else { return }
        selectRegionRange(from: anchorBlock, to: endBlock, among: regionBlocks)
    }

    public mutating func selectLine(containing id: String) {
        guard let block = blocks.first(where: { $0.id == id }) else { return }
        let lineID = block.lineID
        let lineBlocks = blocks.filter { $0.lineID == lineID && $0.displayID == block.displayID }
        selectedIDs = Set(lineBlocks.map(\.id))
        anchorID = lineBlocks.first?.id
    }

    public mutating func selectAll(displayID: UInt32) {
        let onDisplay = blocks.filter { $0.displayID == displayID }
        selectedIDs = Set(onDisplay.map(\.id))
        anchorID = onDisplay.first?.id
    }

    public mutating func clearSelection() {
        selectedIDs = []
        anchorID = nil
    }

    public mutating func selectBlocks(in selectionBounds: CGRect) {
        let bounds = selectionBounds.standardized
        let inRange = blocks.filter { bounds.contains($0.center) }
        selectedIDs = Set(inRange.map(\.id))
        anchorID = inRange.first?.id
    }

    public mutating func selectRange(from startPoint: CGPoint, to endPoint: CGPoint) {
        guard !blocks.isEmpty else { return }

        let startBlock = nearestBlock(to: startPoint)
        let regionBlocks = startBlock.map { blocks(inSameRegionAs: $0) } ?? []
        let endBlock = nearestBlock(to: endPoint, among: regionBlocks)

        guard let start = startBlock, let end = endBlock else { return }
        selectRegionRange(from: start, to: end, among: regionBlocks)
    }

    public mutating func extendRange(to endPoint: CGPoint) {
        guard let anchor = anchorID ?? selectedIDs.first,
              let anchorBlock = blocks.first(where: { $0.id == anchor }),
              let endBlock = nearestBlock(to: endPoint, among: blocks(inSameRegionAs: anchorBlock))
        else {
            return
        }
        selectRegionRange(from: anchorBlock, to: endBlock, among: blocks(inSameRegionAs: anchorBlock))
    }

    private func nearestBlock(to point: CGPoint, among candidates: [ScreenTextBlock]? = nil) -> ScreenTextBlock? {
        (candidates ?? blocks).min { lhs, rhs in
            Self.squaredDistance(from: point, to: lhs.bounds)
                < Self.squaredDistance(from: point, to: rhs.bounds)
        }
    }

    private static func squaredDistance(from point: CGPoint, to bounds: CGRect) -> CGFloat {
        let dx = max(bounds.minX - point.x, 0, point.x - bounds.maxX)
        let dy = max(bounds.minY - point.y, 0, point.y - bounds.maxY)
        return dx * dx + dy * dy
    }

    private func blocks(inSameRegionAs block: ScreenTextBlock) -> [ScreenTextBlock] {
        guard let region = regionByBlockID[block.id] else {
            return [block]
        }
        return blocks.filter { regionByBlockID[$0.id] == region }
    }

    private mutating func selectRegionRange(
        from start: ScreenTextBlock,
        to end: ScreenTextBlock,
        among regionBlocks: [ScreenTextBlock]
    ) {
        guard let startIndex = regionBlocks.firstIndex(where: { $0.id == start.id }),
              let endIndex = regionBlocks.firstIndex(where: { $0.id == end.id })
        else {
            return
        }
        let lower = min(startIndex, endIndex)
        let upper = max(startIndex, endIndex)
        selectedIDs = Set(regionBlocks[lower...upper].map(\.id))
        anchorID = start.id
    }

    public static func deduplicated(_ blocks: [ScreenTextBlock]) -> [ScreenTextBlock] {
        let sourcePreferred = blocks.sorted { lhs, rhs in
            if lhs.source != rhs.source {
                return lhs.source == .accessibility
            }
            return isOrderedBefore(lhs, rhs)
        }

        var accepted: [ScreenTextBlock] = []
        for block in sourcePreferred {
            if accepted.contains(where: { isDuplicate($0, block) }) {
                continue
            }
            accepted.append(block)
        }

        return sortedForReading(accepted)
    }

    private static func sortedForReading(_ blocks: [ScreenTextBlock]) -> [ScreenTextBlock] {
        blocks.sorted(by: isOrderedBefore)
    }

    private static func isOrderedBefore(_ lhs: ScreenTextBlock, _ rhs: ScreenTextBlock) -> Bool {
        if lhs.displayID != rhs.displayID {
            return lhs.displayID < rhs.displayID
        }
        if abs(lhs.bounds.minY - rhs.bounds.minY) > 4 {
            return lhs.bounds.minY < rhs.bounds.minY
        }
        if abs(lhs.bounds.minX - rhs.bounds.minX) > 4 {
            return lhs.bounds.minX < rhs.bounds.minX
        }
        return lhs.id < rhs.id
    }

    private static func isDuplicate(_ existing: ScreenTextBlock, _ candidate: ScreenTextBlock) -> Bool {
        guard existing.displayID == candidate.displayID else {
            return false
        }
        if existing.source != candidate.source {
            return iouOfBounds(existing.bounds, candidate.bounds) >= 0.5
        }
        guard normalized(existing.text) == normalized(candidate.text) else {
            return false
        }
        return overlapRatio(existing.bounds, candidate.bounds) >= 0.6
    }

    private static func normalized(_ text: String) -> String {
        text
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private static func overlapRatio(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull, !intersection.isEmpty else {
            return 0
        }
        let smallerArea = min(lhs.width * lhs.height, rhs.width * rhs.height)
        guard smallerArea > 0 else {
            return 0
        }
        return (intersection.width * intersection.height) / smallerArea
    }

    private static func iouOfBounds(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull, !intersection.isEmpty else {
            return 0
        }
        let intersectionArea = intersection.width * intersection.height
        let unionArea = (lhs.width * lhs.height) + (rhs.width * rhs.height) - intersectionArea
        guard unionArea > 0 else {
            return 0
        }
        return intersectionArea / unionArea
    }

    static func assignLineIDsIfNeeded(_ blocks: [ScreenTextBlock]) -> [ScreenTextBlock] {
        guard blocks.contains(where: { $0.lineID == nil }) else {
            return blocks
        }

        let grouped = Dictionary(grouping: blocks.enumerated().map { ($0.offset, $0.element) }) { $0.1.displayID }

        var assigned = Array(repeating: ScreenTextBlock(id: "", text: "", bounds: .zero, displayID: 0, source: .ocr), count: blocks.count)
        for (displayID, indexed) in grouped {
            let sorted = indexed.sorted { lhs, rhs in
                if abs(lhs.1.bounds.minY - rhs.1.bounds.minY) > 4 {
                    return lhs.1.bounds.minY < rhs.1.bounds.minY
                }
                return lhs.1.bounds.minX < rhs.1.bounds.minX
            }

            var lineIndex = 0
            var lineMidY: CGFloat = -.infinity
            var lineHeight: CGFloat = 0

            for (originalIndex, block) in sorted {
                var updated = block
                if updated.lineID == nil {
                    let referenceMinY = lineMidY - lineHeight / 2
                    let referenceMaxY = lineMidY + lineHeight / 2
                    let verticalOverlap = max(
                        0,
                        min(block.bounds.maxY, referenceMaxY) - max(block.bounds.minY, referenceMinY)
                    )
                    let smallerHeight = min(block.bounds.height, lineHeight)
                    let sharesVisualLine = smallerHeight > 0 && verticalOverlap / smallerHeight >= 0.4

                    if lineIndex == 0 || !sharesVisualLine {
                        lineIndex += 1
                        lineMidY = block.bounds.midY
                        lineHeight = block.bounds.height
                    } else {
                        lineMidY = (lineMidY + block.bounds.midY) / 2
                        lineHeight = (lineHeight + block.bounds.height) / 2
                    }
                    updated.lineID = "\(displayID):\(lineIndex)"
                }
                assigned[originalIndex] = updated
            }
        }

        return assigned
    }

    private struct LineFragment {
        var blocks: [ScreenTextBlock]
        var bounds: CGRect
        var displayID: UInt32
        var lineID: String
    }

    private static func assignTextRegions(_ blocks: [ScreenTextBlock]) -> [String: Int] {
        let groupedLines = Dictionary(grouping: blocks) { block in
            "\(block.displayID)|\(block.lineID ?? block.id)"
        }
        var fragments: [LineFragment] = []

        for lineBlocks in groupedLines.values {
            let sorted = lineBlocks.sorted { $0.bounds.minX < $1.bounds.minX }
            var current: [ScreenTextBlock] = []
            var currentBounds = CGRect.null

            for block in sorted {
                let maximumWordGap = max(24, block.bounds.height * 1.5)
                if let previous = current.last,
                   block.bounds.minX - previous.bounds.maxX > maximumWordGap {
                    fragments.append(LineFragment(
                        blocks: current,
                        bounds: currentBounds,
                        displayID: previous.displayID,
                        lineID: previous.lineID ?? previous.id
                    ))
                    current = []
                    currentBounds = .null
                }
                current.append(block)
                currentBounds = currentBounds.union(block.bounds)
            }

            if let last = current.last {
                fragments.append(LineFragment(
                    blocks: current,
                    bounds: currentBounds,
                    displayID: last.displayID,
                    lineID: last.lineID ?? last.id
                ))
            }
        }

        fragments.sort { lhs, rhs in
            if lhs.displayID != rhs.displayID { return lhs.displayID < rhs.displayID }
            if lhs.bounds.minY != rhs.bounds.minY { return lhs.bounds.minY < rhs.bounds.minY }
            if lhs.bounds.minX != rhs.bounds.minX { return lhs.bounds.minX < rhs.bounds.minX }
            return lhs.lineID < rhs.lineID
        }

        var adjacency = Array(repeating: [Int](), count: fragments.count)
        for leftIndex in fragments.indices {
            for rightIndex in fragments.indices where rightIndex > leftIndex {
                if textFragmentsAreAdjacent(fragments[leftIndex], fragments[rightIndex]) {
                    adjacency[leftIndex].append(rightIndex)
                    adjacency[rightIndex].append(leftIndex)
                }
            }
        }

        var result: [String: Int] = [:]
        var visited: Set<Int> = []
        var region = 0

        for startIndex in fragments.indices where !visited.contains(startIndex) {
            var pending = [startIndex]
            visited.insert(startIndex)

            while let fragmentIndex = pending.popLast() {
                for block in fragments[fragmentIndex].blocks {
                    result[block.id] = region
                }
                for neighbor in adjacency[fragmentIndex] where !visited.contains(neighbor) {
                    visited.insert(neighbor)
                    pending.append(neighbor)
                }
            }
            region += 1
        }

        return result
    }

    private static func textFragmentsAreAdjacent(_ lhs: LineFragment, _ rhs: LineFragment) -> Bool {
        guard lhs.displayID == rhs.displayID, lhs.lineID != rhs.lineID else {
            return false
        }

        let verticalGap = max(
            0,
            max(lhs.bounds.minY, rhs.bounds.minY) - min(lhs.bounds.maxY, rhs.bounds.maxY)
        )
        let maximumLineGap = max(24, max(lhs.bounds.height, rhs.bounds.height) * 1.5)
        guard verticalGap <= maximumLineGap else {
            return false
        }

        let horizontalOverlap = max(
            0,
            min(lhs.bounds.maxX, rhs.bounds.maxX) - max(lhs.bounds.minX, rhs.bounds.minX)
        )
        let smallerWidth = min(lhs.bounds.width, rhs.bounds.width)
        let overlapsSubstantially = smallerWidth > 0 && horizontalOverlap / smallerWidth >= 0.2
        let leftEdgesAlign = abs(lhs.bounds.minX - rhs.bounds.minX) <= max(
            36,
            max(lhs.bounds.height, rhs.bounds.height) * 2
        )
        return overlapsSubstantially || leftEdgesAlign
    }
}
