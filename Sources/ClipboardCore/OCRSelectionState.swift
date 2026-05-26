import Foundation

public struct OCRTextBlock: Equatable, Identifiable, Sendable {
    public let id: String
    public var text: String

    public init(id: String, text: String) {
        self.id = id
        self.text = text
    }
}

public struct OCRSelectionState: Equatable, Sendable {
    public var blocks: [OCRTextBlock]
    public private(set) var selectedIDs: Set<String>

    public init(blocks: [OCRTextBlock], selectedIDs: Set<String> = []) {
        self.blocks = blocks
        self.selectedIDs = selectedIDs
    }

    public var canCopySelection: Bool {
        !selectedIDs.isEmpty
    }

    public var selectedText: String {
        blocks
            .filter { selectedIDs.contains($0.id) }
            .map(\.text)
            .joined(separator: "\n")
    }

    public mutating func toggle(_ id: String) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
    }
}
