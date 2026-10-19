// SPDX-License-Identifier: MPL-2.0

import AppKit
@testable import EarlyBrowser
import Testing

@Suite(.serialized) @MainActor
struct CommandBarInputTests {
    private func makeControl(width: CGFloat = 460, maxHeight: CGFloat = 120) -> CommandBarInputControl {
        _ = NSApplication.shared
        let control = CommandBarInputControl(frame: NSRect(x: 0, y: 0, width: width, height: 24))
        control.maximumHeight = maxHeight
        control.measure(width: width)
        return control
    }

    @Test func nativeEditorKeepsTheExistingTextFieldAccessibilityContract() {
        let control = makeControl()
        defer { control.invalidate() }
        #expect(control.textView.accessibilityRole() == .textField)
        #expect(control.textView.accessibilitySubrole() == nil)
        #expect(control.textView.accessibilityIdentifier() == "commandBar.query")
        #expect(control.textView.accessibilityLabel() == "Search or enter a URL")
        #expect(control.textView.accessibilityPlaceholderValue() == "Search or enter a URL")
        #expect(control.textView.insertionPointColor == .secondaryLabelColor)
        #expect(!control.textView.isRichText)
        #expect(control.textView.allowsUndo)
        #expect(!control.scrollView.hasHorizontalScroller)
        control.updateText("a multiline\naccessible query")
        #expect(control.textView.accessibilityValue() == "a multiline\naccessible query")
    }

    @Test func aShortQueryStaysOneLineAndWrappingAdaptsToNarrowerWindows() {
        let control = makeControl(width: 460)
        defer { control.invalidate() }
        control.updateText("hello")
        let short = control.measure(width: 460)
        #expect(short == CommandBarInputControl.minimumHeight)
        #expect(!control.scrollView.hasVerticalScroller)

        control.updateText("A search with several ordinary words that should wrap naturally as the window narrows")
        let wide = control.measure(width: 460)
        let narrow = control.measure(width: 160)
        #expect(narrow > wide)
        #expect(narrow <= 120)
        #expect(control.textView.frame.width == 160)
        #expect(control.textView.textContainer?.containerSize.width == 160)
    }

    @Test func anUnbrokenURLWrapsAndLargePastesScrollInsideTheHeightLimit() {
        let control = makeControl(width: 150, maxHeight: 96)
        defer { control.invalidate() }
        let url = "https://example.com/" + String(repeating: "long-unbroken-path-segment", count: 500)
        control.updateText(url)
        let height = control.measure(width: 150)
        #expect(height == 96)
        #expect(control.contentHeight > height)
        #expect(control.textView.string == url)
        #expect(control.textView.frame.width == 150)
        #expect(control.textView.frame.height == control.contentHeight)
        #expect(control.scrollView.hasVerticalScroller)
        #expect(!control.scrollView.hasHorizontalScroller)
    }

    @Test func explicitNewlinesGrowAndTrailingBlankLinesKeepTheirCaretVisible() {
        let control = makeControl()
        defer { control.invalidate() }
        control.updateText("first\nsecond")
        let twoLines = control.measure(width: 460)
        control.updateText("first\nsecond\n")
        let trailingLine = control.measure(width: 460)
        #expect(twoLines > CommandBarInputControl.minimumHeight)
        #expect(trailingLine > twoLines)
        control.updateText("short")
        #expect(control.measure(width: 460) == CommandBarInputControl.minimumHeight)
        #expect(!control.scrollView.hasVerticalScroller)
    }

    @Test func theEndCaretRemainsReachableAfterACappedPasteAndNarrowResize() throws {
        let control = makeControl(width: 200, maxHeight: 96)
        defer { control.invalidate() }
        control.frame.size.height = 96
        let query = "https://example.com/" + String(repeating: "longpathsegment", count: 200)
        control.updateText(query)
        control.measure(width: 200)
        let selection = NSRange(location: (query as NSString).length, length: 0)
        control.textView.setSelectedRange(selection)
        control.textView.scrollRangeToVisible(selection)
        let manager = try #require(control.textView.layoutManager)
        let container = try #require(control.textView.textContainer)
        let lastGlyph = NSRange(location: manager.numberOfGlyphs - 1, length: 1)
        let bottomBeforeResize = manager.boundingRect(forGlyphRange: lastGlyph, in: container).maxY
        #expect(control.scrollView.documentVisibleRect.maxY >= bottomBeforeResize - 1)
        #expect(control.scrollView.documentVisibleRect.height <= 96)
        #expect(control.scrollView.documentVisibleRect.minY > 0)

        control.frame.size.width = 100
        control.layoutSubtreeIfNeeded()
        // No window or first responder is created in this test. Invoke the same
        // native visibility primitive the focused editor uses after a resize.
        control.textView.scrollRangeToVisible(selection)
        let bottomAfterResize = manager.boundingRect(forGlyphRange: lastGlyph, in: container).maxY
        #expect(bottomAfterResize > bottomBeforeResize)
        #expect(control.textView.selectedRange() == selection)
        #expect(control.scrollView.documentVisibleRect.maxY >= bottomAfterResize - 1)
        #expect(control.scrollView.documentVisibleRect.height <= 96)
        #expect(control.textView.frame.width == 100)
    }

    @Test func heightLimitsAreFiniteAndNeverCollapseBelowOneLine() {
        let control = makeControl(width: 80, maxHeight: 0)
        defer { control.invalidate() }
        control.updateText(String(repeating: "query ", count: 100))
        #expect(control.measure(width: 80) == CommandBarInputControl.minimumHeight)
        control.maximumHeight = .infinity
        #expect(control.measure(width: 80) == 120)
        #expect(control.measure(width: .nan).isFinite)
    }

    @Test func observationEchoesPreserveSelectionAndNativeUndoRedo() {
        let control = makeControl()
        defer { control.invalidate() }
        control.updateText("hello")
        control.textView.setSelectedRange(NSRange(location: 5, length: 0))
        control.textView.insertText(" world", replacementRange: NSRange(location: NSNotFound, length: 0))
        control.textView.breakUndoCoalescing()
        control.textView.setSelectedRange(NSRange(location: 2, length: 3))
        let selection = control.textView.selectedRange()
        let canUndo = control.textView.undoManager?.canUndo

        control.updateText("hello world")
        #expect(control.textView.selectedRange() == selection)
        #expect(control.textView.undoManager?.canUndo == canUndo)
        #expect(canUndo == true)

        control.textView.undoManager?.undo()
        #expect(control.textView.string == "hello")
        control.textView.undoManager?.redo()
        #expect(control.textView.string == "hello world")
    }

    @Test func externalQueryReplacementClampsSelectionAndClearsOnlyOldEditHistory() {
        let control = makeControl()
        defer { control.invalidate() }
        control.updateText("a much longer query")
        control.textView.setSelectedRange(NSRange(location: 10, length: 6))
        control.textView.insertText("changed", replacementRange: NSRange(location: NSNotFound, length: 0))
        control.textView.breakUndoCoalescing()
        control.updateText("new")
        #expect(control.textView.string == "new")
        #expect(control.textView.selectedRange() == NSRange(location: 3, length: 0))
        #expect(control.textView.undoManager?.canUndo == false)
    }

    @Test func returnAndEscapeRouteOnceButShiftReturnAndNativeEditingStayNative() {
        let control = makeControl()
        defer { control.invalidate() }
        var submitted = 0
        var cancelled = 0
        control.onSubmit = { submitted += 1 }
        control.onCancel = { cancelled += 1 }
        #expect(control.handleCommand(#selector(NSResponder.insertNewline(_:))))
        #expect(control.handleCommand(#selector(NSResponder.cancelOperation(_:))))
        #expect(submitted == 1 && cancelled == 1)
        #expect(!control.handleCommand(#selector(NSResponder.insertNewline(_:)), modifiers: .shift))
        #expect(!control.handleCommand(#selector(NSResponder.insertNewlineIgnoringFieldEditor(_:))))
        #expect(!control.handleCommand(#selector(NSResponder.selectAll(_:)), modifiers: .command))
        #expect(!control.handleCommand(#selector(NSResponder.moveLeft(_:))))
        #expect(!control.handleCommand(#selector(NSResponder.deleteBackward(_:))))
        #expect(submitted == 1 && cancelled == 1)
    }

    @Test func suggestionArrowsAreConsumedOnlyWhenTheirActionAcceptsThem() {
        let control = makeControl()
        defer { control.invalidate() }
        var deltas = [Int]()
        #expect(!control.handleCommand(#selector(NSResponder.moveDown(_:))))
        control.onMoveSelection = { deltas.append($0); return true }
        #expect(control.handleCommand(#selector(NSResponder.moveDown(_:))))
        #expect(control.handleCommand(#selector(NSResponder.moveUp(_:))))
        #expect(deltas == [1, -1])
        #expect(!control.handleCommand(#selector(NSResponder.moveUp(_:)), modifiers: .shift))
        #expect(!control.handleCommand(#selector(NSResponder.moveDown(_:)), modifiers: .command))
        #expect(deltas == [1, -1])
    }

    @Test func composingTextKeepsCandidateCommandsAndPrecedesQueryPublication() {
        let control = makeControl()
        defer { control.invalidate() }
        var events = [String]()
        var browserCommands = 0
        control.onCompositionChange = { events.append($0 ? "composition began" : "composition ended") }
        control.onTextChange = { events.append("query: \($0)") }
        control.onSubmit = { browserCommands += 1 }
        control.onCancel = { browserCommands += 1 }
        control.onMoveSelection = { _ in browserCommands += 1; return true }

        control.textView.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(control.isComposing)
        #expect(control.textView.hasMarkedText())
        #expect(events.first == "composition began")
        #expect(!control.handleCommand(#selector(NSResponder.insertNewline(_:))))
        #expect(!control.handleCommand(#selector(NSResponder.cancelOperation(_:))))
        #expect(!control.handleCommand(#selector(NSResponder.moveDown(_:))))
        #expect(browserCommands == 0)

        control.updateText("an observation echo must not replace the candidate")
        #expect(control.textView.string == "に")
        control.textView.insertText("日本", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(!control.isComposing)
        #expect(!control.textView.hasMarkedText())
        #expect(control.textView.string == "日本")
        #expect(events.last == "composition ended")
        #expect(control.handleCommand(#selector(NSResponder.insertNewline(_:))))
        #expect(browserCommands == 1)
    }

    @Test func onlyAnExplicitNewPresentationCanReplaceAnUnfinishedCandidate() {
        let control = makeControl()
        defer { control.invalidate() }
        var publishedQueries = [String]()
        control.onTextChange = { publishedQueries.append($0) }
        control.requestFocus(1)
        control.textView.setMarkedText("候補", selectedRange: NSRange(location: 2, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0))

        control.prepareForFocusRequest(1)
        control.updateText("an ordinary observation update")
        #expect(control.isComposing)
        #expect(control.textView.string == "候補")

        publishedQueries.removeAll()
        control.prepareForFocusRequest(2)
        control.updateText("https://example.com/new-presentation")
        control.requestFocus(2)
        #expect(!control.isComposing)
        #expect(!control.textView.hasMarkedText())
        #expect(control.textView.string == "https://example.com/new-presentation")
        #expect(publishedQueries.isEmpty)
    }

    @Test func updatesAndPendingFocusNeverAcquireAResponderWithoutAVisibleWindow() {
        let control = makeControl()
        var focusChanges = [Bool]()
        control.onFocusChange = { focusChanges.append($0) }
        control.requestFocus(1)
        control.requestFocus(1)
        control.updateText("a query redraw")
        control.measure(width: 180)
        control.requestFocus(2)
        control.invalidate()
        control.requestFocus(3)
        #expect(focusChanges.isEmpty)
        #expect(control.window == nil)
        #expect(control.textView.delegate == nil)
    }
}
