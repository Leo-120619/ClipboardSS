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

    public init(
        blocks: [ScreenTextBlock],
        selectedIDs: Set<String> = [],
        anchorID: String? = nil,
        joinMode: ScreenTextJoinMode = .lines
    ) {
        let prepared = Self.sortedForReading(Self.deduplicated(blocks))
        self.blocks = Self.assignLineIDsIfNeeded(prepared)
        self.selectedIDs = selectedIDs
        self.anchorID = anchorID
        self.joinMode = joinMode
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
        guard let startIndex = blocks.firstIndex(where: { $0.id == anchor }),
              let endIndex = blocks.firstIndex(where: { $0.id == id })
        else {
            return
        }
        let lower = min(startIndex, endIndex)
        let upper = max(startIndex, endIndex)
        selectedIDs = Set(blocks[lower...upper].map(\.id))
        anchorID = anchor
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
        let endBlock = nearestBlock(to: endPoint)

        guard let start = startBlock, let end = endBlock,
              let startIndex = blocks.firstIndex(where: { $0.id == start.id }),
              let endIndex = blocks.firstIndex(where: { $0.id == end.id })
        else {
            return
        }

        let lower = min(startIndex, endIndex)
        let upper = max(startIndex, endIndex)

        selectedIDs = Set(blocks[lower...upper].map(\.id))
        anchorID = start.id
    }

    public mutating func extendRange(to endPoint: CGPoint) {
        guard let anchor = anchorID ?? selectedIDs.first,
              let anchorBlock = blocks.first(where: { $0.id == anchor }),
              let endBlock = nearestBlock(to: endPoint),
              let startIndex = blocks.firstIndex(where: { $0.id == anchorBlock.id }),
              let endIndex = blocks.firstIndex(where: { $0.id == endBlock.id })
        else {
            return
        }
        let lower = min(startIndex, endIndex)
        let upper = max(startIndex, endIndex)
        selectedIDs = Set(blocks[lower...upper].map(\.id))
        anchorID = anchorBlock.id
    }

    private func nearestBlock(to point: CGPoint) -> ScreenTextBlock? {
        blocks.min { lhs, rhs in
            let dx0 = lhs.center.x - point.x
            let dy0 = lhs.center.y - point.y
            let dx1 = rhs.center.x - point.x
            let dy1 = rhs.center.y - point.y
            return (dx0 * dx0 + dy0 * dy0) < (dx1 * dx1 + dy1 * dy1)
        }
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
            var lineMinY: CGFloat = -.infinity
            var lineHeight: CGFloat = 0

            for (originalIndex, block) in sorted {
                var updated = block
                if updated.lineID == nil {
                    let threshold = max(4, min(block.bounds.height, lineHeight) * 0.5)
                    if abs(block.bounds.minY - lineMinY) > threshold {
                        lineIndex += 1
                        lineMinY = block.bounds.minY
                        lineHeight = block.bounds.height
                    } else {
                        lineHeight = (lineHeight + block.bounds.height) / 2
                    }
                    updated.lineID = "\(displayID):\(lineIndex)"
                }
                assigned[originalIndex] = updated
            }
        }

        return assigned
    }
}
