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

    @Test("drag selection stays inside the paragraph column")
    func dragSelectionExcludesParallelSidebarText() {
        var selection = ScreenTextSelectionState(blocks: [
            ScreenTextBlock(id: "sidebar-1", text: "Create test environment", bounds: CGRect(x: 20, y: 0, width: 180, height: 18), displayID: 1, source: .ocr),
            ScreenTextBlock(id: "paragraph-1a", text: "Proceeding from the approved", bounds: CGRect(x: 300, y: 0, width: 210, height: 18), displayID: 1, source: .ocr),
            ScreenTextBlock(id: "paragraph-1b", text: "specification", bounds: CGRect(x: 520, y: 0, width: 90, height: 18), displayID: 1, source: .ocr),
            ScreenTextBlock(id: "sidebar-2", text: "Gather enriched leads", bounds: CGRect(x: 20, y: 30, width: 170, height: 18), displayID: 1, source: .ocr),
            ScreenTextBlock(id: "paragraph-2", text: "first implementation plan with exact files", bounds: CGRect(x: 300, y: 30, width: 310, height: 18), displayID: 1, source: .ocr),
            ScreenTextBlock(id: "sidebar-3", text: "Build enriched lead CSV", bounds: CGRect(x: 20, y: 60, width: 180, height: 18), displayID: 1, source: .ocr),
            ScreenTextBlock(id: "paragraph-3", text: "changes", bounds: CGRect(x: 300, y: 60, width: 70, height: 18), displayID: 1, source: .ocr)
        ])

        selection.selectRange(
            from: CGPoint(x: 405, y: 9),
            to: CGPoint(x: 335, y: 69)
        )

        #expect(selection.selectedIDs == ["paragraph-1a", "paragraph-1b", "paragraph-2", "paragraph-3"])
        #expect(selection.selectedText == "Proceeding from the approved specification\nfirst implementation plan with exact files\nchanges")
    }

    @Test("shift extension stays inside the anchor paragraph column")
    func shiftExtensionExcludesParallelSidebarText() {
        var selection = ScreenTextSelectionState(blocks: [
            ScreenTextBlock(id: "paragraph-1", text: "First line", bounds: CGRect(x: 300, y: 0, width: 120, height: 18), displayID: 1, source: .ocr),
            ScreenTextBlock(id: "sidebar-2", text: "Unrelated sidebar", bounds: CGRect(x: 20, y: 30, width: 160, height: 18), displayID: 1, source: .ocr),
            ScreenTextBlock(id: "paragraph-2", text: "Second line", bounds: CGRect(x: 300, y: 30, width: 130, height: 18), displayID: 1, source: .ocr),
            ScreenTextBlock(id: "sidebar-3", text: "Another sidebar item", bounds: CGRect(x: 20, y: 60, width: 180, height: 18), displayID: 1, source: .ocr),
            ScreenTextBlock(id: "paragraph-3", text: "Third line", bounds: CGRect(x: 300, y: 60, width: 110, height: 18), displayID: 1, source: .ocr)
        ])

        selection.select("paragraph-1")
        selection.extend(to: "paragraph-3")

        #expect(selection.selectedIDs == ["paragraph-1", "paragraph-2", "paragraph-3"])
        #expect(selection.selectedText == "First line\nSecond line\nThird line")
    }

    @Test("shift drag stays inside the anchor paragraph column")
    func shiftDragExcludesParallelSidebarText() {
        var selection = ScreenTextSelectionState(blocks: [
            ScreenTextBlock(id: "paragraph-1", text: "First line", bounds: CGRect(x: 300, y: 0, width: 120, height: 18), displayID: 1, source: .ocr),
            ScreenTextBlock(id: "sidebar-2", text: "Unrelated sidebar", bounds: CGRect(x: 20, y: 30, width: 160, height: 18), displayID: 1, source: .ocr),
            ScreenTextBlock(id: "paragraph-2", text: "Second line", bounds: CGRect(x: 300, y: 30, width: 130, height: 18), displayID: 1, source: .ocr),
            ScreenTextBlock(id: "sidebar-3", text: "Another sidebar item", bounds: CGRect(x: 20, y: 60, width: 180, height: 18), displayID: 1, source: .ocr),
            ScreenTextBlock(id: "paragraph-3", text: "Third line", bounds: CGRect(x: 300, y: 60, width: 110, height: 18), displayID: 1, source: .ocr)
        ])

        selection.select("paragraph-1")
        selection.extendRange(to: CGPoint(x: 355, y: 69))

        #expect(selection.selectedIDs == ["paragraph-1", "paragraph-2", "paragraph-3"])
        #expect(selection.selectedText == "First line\nSecond line\nThird line")
    }

    @Test("drag uses the words containing its endpoints in either direction")
    func dragSelectsPartialFirstAndLastLinesInEitherDirection() {
        let blocks = [
            ScreenTextBlock(id: "before", text: "Before", bounds: CGRect(x: 300, y: 0, width: 40, height: 18), displayID: 1, source: .ocr),
            ScreenTextBlock(id: "start", text: "selected beginning phrase", bounds: CGRect(x: 350, y: 0, width: 200, height: 18), displayID: 1, source: .ocr),
            ScreenTextBlock(id: "first-trailing", text: "continues", bounds: CGRect(x: 560, y: 0, width: 50, height: 18), displayID: 1, source: .ocr),
            ScreenTextBlock(id: "last-leading", text: "and finishes", bounds: CGRect(x: 300, y: 30, width: 60, height: 18), displayID: 1, source: .ocr),
            ScreenTextBlock(id: "end", text: "inside this phrase", bounds: CGRect(x: 370, y: 30, width: 200, height: 18), displayID: 1, source: .ocr),
            ScreenTextBlock(id: "after", text: "After", bounds: CGRect(x: 580, y: 30, width: 40, height: 18), displayID: 1, source: .ocr)
        ]
        let startPoint = CGPoint(x: 351, y: 9)
        let endPoint = CGPoint(x: 569, y: 39)
        let expectedIDs: Set<String> = ["start", "first-trailing", "last-leading", "end"]

        var forwardSelection = ScreenTextSelectionState(blocks: blocks)
        forwardSelection.selectRange(from: startPoint, to: endPoint)

        var reverseSelection = ScreenTextSelectionState(blocks: blocks)
        reverseSelection.selectRange(from: endPoint, to: startPoint)

        #expect(forwardSelection.selectedIDs == expectedIDs)
        #expect(reverseSelection.selectedIDs == expectedIDs)
        #expect(forwardSelection.selectedText == "selected beginning phrase continues\nand finishes inside this phrase")
        #expect(reverseSelection.selectedText == forwardSelection.selectedText)
    }

    @Test("vertically jittered OCR words stay in the same paragraph line")
    func dragIncludesOverlappingWordsWithDifferentVerticalOrigins() {
        var selection = ScreenTextSelectionState(blocks: [
            ScreenTextBlock(id: "line-1a", text: "The", bounds: CGRect(x: 300, y: 0, width: 40, height: 20), displayID: 1, source: .ocr),
            ScreenTextBlock(id: "line-1b", text: "updated app", bounds: CGRect(x: 350, y: 11, width: 180, height: 20), displayID: 1, source: .ocr),
            ScreenTextBlock(id: "line-2a", text: "remains", bounds: CGRect(x: 300, y: 40, width: 100, height: 20), displayID: 1, source: .ocr),
            ScreenTextBlock(id: "line-2b", text: "running", bounds: CGRect(x: 410, y: 40, width: 100, height: 20), displayID: 1, source: .ocr)
        ])

        selection.selectRange(
            from: CGPoint(x: 320, y: 10),
            to: CGPoint(x: 460, y: 50)
        )

        #expect(selection.selectedIDs == ["line-1a", "line-1b", "line-2a", "line-2b"])
        #expect(selection.selectedText == "The updated app\nremains running")
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

    @Test("words on one line stay left-to-right even when their tops differ")
    func mixedHeightWordsKeepLineOrder() {
        var selection = ScreenTextSelectionState(blocks: [
            ScreenTextBlock(id: "z-small", text: "small", bounds: CGRect(x: 0, y: 10, width: 36, height: 12), displayID: 1, source: .ocr),
            ScreenTextBlock(id: "a-big", text: "Big", bounds: CGRect(x: 40, y: 0, width: 40, height: 30), displayID: 1, source: .ocr)
        ])

        selection.selectAll(displayID: 1)

        #expect(selection.selectedText == "small Big")
    }

    @Test("blocks sharing an OCR lineID are ordered by x, never by id")
    func providedLineIDsAreRespected() {
        var selection = ScreenTextSelectionState(blocks: [
            ScreenTextBlock(id: "a", text: "world", bounds: CGRect(x: 60, y: 6, width: 50, height: 14), displayID: 1, source: .ocr, lineID: "L1"),
            ScreenTextBlock(id: "b", text: "hello", bounds: CGRect(x: 0, y: 0, width: 50, height: 20), displayID: 1, source: .ocr, lineID: "L1"),
            ScreenTextBlock(id: "c", text: "next", bounds: CGRect(x: 0, y: 30, width: 40, height: 20), displayID: 1, source: .ocr, lineID: "L2")
        ])

        selection.selectAll(displayID: 1)

        #expect(selection.selectedText == "hello world\nnext")
    }

    @Test("dragging from mid first line to mid last line selects the reading-order range")
    func dragAcrossLinesSelectsReadingRange() {
        var selection = ScreenTextSelectionState(blocks: [
            ScreenTextBlock(id: "1a", text: "one", bounds: CGRect(x: 0, y: 0, width: 30, height: 18), displayID: 1, source: .ocr),
            ScreenTextBlock(id: "1b", text: "two", bounds: CGRect(x: 40, y: 0, width: 30, height: 18), displayID: 1, source: .ocr),
            ScreenTextBlock(id: "2a", text: "three", bounds: CGRect(x: 0, y: 30, width: 30, height: 18), displayID: 1, source: .ocr),
            ScreenTextBlock(id: "2b", text: "four", bounds: CGRect(x: 40, y: 30, width: 30, height: 18), displayID: 1, source: .ocr)
        ])

        selection.selectRange(from: CGPoint(x: 55, y: 9), to: CGPoint(x: 15, y: 39))

        #expect(selection.selectedText == "two\nthree")
    }
}
