import Testing
@testable import ClipboardCore

@Suite("OCR selection")
struct OCRSelectionTests {
    @Test("copy text is unavailable until at least one OCR block is selected")
    func copyTextRequiresSelection() {
        var selection = OCRSelectionState(blocks: [
            OCRTextBlock(id: "a", text: "Alpha"),
            OCRTextBlock(id: "b", text: "Beta")
        ])

        #expect(selection.selectedText == "")
        #expect(selection.canCopySelection == false)

        selection.toggle("b")

        #expect(selection.selectedText == "Beta")
        #expect(selection.canCopySelection)

        selection.toggle("a")

        #expect(selection.selectedText == "Alpha\nBeta")
    }
}
