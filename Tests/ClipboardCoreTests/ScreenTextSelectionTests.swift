import CoreGraphics
import Testing
@testable import ClipboardCore

@Suite("Screen text selection")
struct ScreenTextSelectionTests {
    @Test("rectangle selection copies blocks whose centers are inside the rectangle")
    func rectangleSelectionCopiesBlocksInsideSelectionBounds() {
        var selection = ScreenTextSelectionState(blocks: [
            ScreenTextBlock(id: "a", text: "Alpha", bounds: CGRect(x: 10, y: 10, width: 80, height: 20), displayID: 1, source: .ocr),
            ScreenTextBlock(id: "b", text: "Beta", bounds: CGRect(x: 120, y: 10, width: 80, height: 20), displayID: 1, source: .accessibility),
            ScreenTextBlock(id: "c", text: "Gamma", bounds: CGRect(x: 260, y: 10, width: 80, height: 20), displayID: 1, source: .ocr)
        ])

        selection.selectBlocks(in: CGRect(x: 220, y: 60, width: -220, height: -60))

        #expect(selection.selectedIDs == ["a", "b"])
        #expect(selection.selectedText == "Alpha Beta")
    }

    @Test("clicked selections copy in screen reading order rather than click order")
    func clickedSelectionsCopyInReadingOrder() {
        var selection = ScreenTextSelectionState(blocks: [
            ScreenTextBlock(id: "top", text: "First", bounds: CGRect(x: 20, y: 20, width: 80, height: 18), displayID: 1, source: .ocr),
            ScreenTextBlock(id: "bottom", text: "Second", bounds: CGRect(x: 20, y: 60, width: 80, height: 18), displayID: 1, source: .ocr)
        ])

        selection.toggle("bottom")
        selection.toggle("top")

        #expect(selection.selectedText == "First\nSecond")
    }

    @Test("deduplication prefers accessibility blocks over overlapping OCR blocks")
    func deduplicationPrefersAccessibilityBlocks() {
        let blocks = ScreenTextSelectionState.deduplicated([
            ScreenTextBlock(id: "ocr-overlap", text: "Account Balance", bounds: CGRect(x: 20, y: 20, width: 140, height: 20), displayID: 1, source: .ocr),
            ScreenTextBlock(id: "accessibility", text: "Account Balance", bounds: CGRect(x: 18, y: 18, width: 144, height: 24), displayID: 1, source: .accessibility),
            ScreenTextBlock(id: "ocr-distinct", text: "Account Balance", bounds: CGRect(x: 20, y: 120, width: 140, height: 20), displayID: 1, source: .ocr)
        ])

        #expect(blocks.map(\.id) == ["accessibility", "ocr-distinct"])
    }

    @Test("spatial dedup drops OCR twin even when text differs from accessibility block")
    func spatialDedupDropsOCRTwinWithDifferingText() {
        let blocks = ScreenTextSelectionState.deduplicated([
            ScreenTextBlock(id: "ocr", text: "lmport", bounds: CGRect(x: 20, y: 20, width: 100, height: 20), displayID: 1, source: .ocr),
            ScreenTextBlock(id: "ax", text: "import", bounds: CGRect(x: 22, y: 21, width: 96, height: 18), displayID: 1, source: .accessibility)
        ])

        #expect(blocks.map(\.id) == ["ax"])
    }

    @Test("shift-extend selects reading-order range from anchor to target")
    func extendSelectsRangeFromAnchor() {
        var selection = ScreenTextSelectionState(blocks: [
            ScreenTextBlock(id: "w1", text: "one", bounds: CGRect(x: 0, y: 0, width: 30, height: 18), displayID: 1, source: .ocr),
            ScreenTextBlock(id: "w2", text: "two", bounds: CGRect(x: 40, y: 0, width: 30, height: 18), displayID: 1, source: .ocr),
            ScreenTextBlock(id: "w3", text: "three", bounds: CGRect(x: 0, y: 30, width: 50, height: 18), displayID: 1, source: .ocr),
            ScreenTextBlock(id: "w4", text: "four", bounds: CGRect(x: 60, y: 30, width: 40, height: 18), displayID: 1, source: .ocr)
        ])

        selection.select("w1")
        selection.extend(to: "w3")

        #expect(selection.selectedIDs == ["w1", "w2", "w3"])
        #expect(selection.anchorID == "w1")
    }

    @Test("triple-click selects every block on the same line")
    func selectLineSelectsSameLineBlocks() {
        var selection = ScreenTextSelectionState(blocks: [
            ScreenTextBlock(id: "w1", text: "one", bounds: CGRect(x: 0, y: 0, width: 30, height: 18), displayID: 1, source: .ocr),
            ScreenTextBlock(id: "w2", text: "two", bounds: CGRect(x: 40, y: 1, width: 30, height: 18), displayID: 1, source: .ocr),
            ScreenTextBlock(id: "w3", text: "three", bounds: CGRect(x: 0, y: 60, width: 50, height: 18), displayID: 1, source: .ocr)
        ])

        selection.selectLine(containing: "w2")

        #expect(selection.selectedIDs == ["w1", "w2"])
    }

    @Test("select-all only selects blocks on the focused display")
    func selectAllFiltersByDisplay() {
        var selection = ScreenTextSelectionState(blocks: [
            ScreenTextBlock(id: "a", text: "a", bounds: CGRect(x: 0, y: 0, width: 10, height: 10), displayID: 1, source: .ocr),
            ScreenTextBlock(id: "b", text: "b", bounds: CGRect(x: 0, y: 20, width: 10, height: 10), displayID: 1, source: .ocr),
            ScreenTextBlock(id: "c", text: "c", bounds: CGRect(x: 0, y: 0, width: 10, height: 10), displayID: 2, source: .ocr)
        ])

        selection.selectAll(displayID: 1)

        #expect(selection.selectedIDs == ["a", "b"])
    }

    @Test("joinedText(.spaces) joins all selected blocks with single spaces")
    func joinedTextSpacesMode() {
        var selection = ScreenTextSelectionState(blocks: [
            ScreenTextBlock(id: "w1", text: "one", bounds: CGRect(x: 0, y: 0, width: 30, height: 18), displayID: 1, source: .ocr),
            ScreenTextBlock(id: "w2", text: "two", bounds: CGRect(x: 0, y: 30, width: 30, height: 18), displayID: 1, source: .ocr),
            ScreenTextBlock(id: "w3", text: "three", bounds: CGRect(x: 0, y: 60, width: 50, height: 18), displayID: 1, source: .ocr)
        ])

        selection.selectAll(displayID: 1)

        #expect(selection.joinedText(mode: .spaces) == "one two three")
        #expect(selection.joinedText(mode: .lines) == "one\ntwo\nthree")
    }

    @Test("clearSelection removes selection and anchor")
    func clearSelectionResets() {
        var selection = ScreenTextSelectionState(blocks: [
            ScreenTextBlock(id: "w1", text: "one", bounds: CGRect(x: 0, y: 0, width: 30, height: 18), displayID: 1, source: .ocr)
        ])

        selection.select("w1")
        selection.clearSelection()

        #expect(selection.selectedIDs.isEmpty)
        #expect(selection.anchorID == nil)
    }
}
