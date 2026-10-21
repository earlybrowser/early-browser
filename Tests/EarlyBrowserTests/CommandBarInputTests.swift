// SPDX-License-Identifier: MPL-2.0

import AppKit
@testable import EarlyBrowser
import Testing

@Suite(.serialized) @MainActor
struct CommandBarInputTests {
    private final class FocusTarget: NSView {
        override var acceptsFirstResponder: Bool { true }
    }

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
        #expect(control.textView.inlinePredictionType == .no)
        if #available(macOS 15.0, *) { #expect(control.textView.writingToolsBehavior == .none) }
        #expect(!control.scrollView.hasHorizontalScroller)
        control.updateText("a multiline\naccessible query")
        #expect(control.textView.accessibilityValue() == "a multiline\naccessible query")
    }

    @Test func tabAndBacktabTraverseTheNativeKeyLoopWithoutEditingOrSubmitting() throws {
        let control = makeControl()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 200),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 200))
        let previous = FocusTarget(frame: NSRect(x: 0, y: 80, width: 40, height: 30))
        let next = FocusTarget(frame: NSRect(x: 500, y: 80, width: 40, height: 30))
        root.addSubview(previous); root.addSubview(control); root.addSubview(next)
        window.contentView = root
        window.autorecalculatesKeyViewLoop = false
        previous.nextKeyView = control.textView
        control.textView.nextKeyView = next
        next.nextKeyView = previous
        defer { control.invalidate(); window.contentView = nil; window.close() }
        control.updateText("keep this query")
        var edits = 0, submissions = 0
        control.onTextChange = { _ in edits += 1 }
        control.onSubmit = { submissions += 1 }
        #expect(window.makeFirstResponder(control.textView))
        #expect(control.handleCommand(#selector(NSResponder.insertTab(_:))))
        #expect(window.firstResponder === next)
        #expect(window.makeFirstResponder(control.textView))
        #expect(control.handleCommand(#selector(NSResponder.insertBacktab(_:)), modifiers: .shift))
        #expect(window.firstResponder === previous)
        #expect(window.makeFirstResponder(control.textView))
        #expect(control.handleCommand(#selector(NSResponder.insertTab(_:)), modifiers: .shift))
        #expect(window.firstResponder === previous)
        #expect(control.textView.string == "keep this query" && edits == 0 && submissions == 0)
        #expect(!window.isVisible)
    }

    @Test func tabTraversalLeavesInputMethodsAndModifiedKeysToAppKit() {
        let control = makeControl()
        defer { control.invalidate() }
        let tab = #selector(NSResponder.insertTab(_:)), backtab = #selector(NSResponder.insertBacktab(_:))
        for modifiers: NSEvent.ModifierFlags in [.command, .control, .option, [.control, .option]] {
            #expect(!control.handleCommand(tab, modifiers: modifiers))
            #expect(!control.handleCommand(backtab, modifiers: modifiers))
        }
        control.textView.setMarkedText("candidate", selectedRange: NSRange(location: 9, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(control.textView.hasMarkedText())
        #expect(!control.handleCommand(tab) && !control.handleCommand(backtab))
        #expect(control.textView.hasMarkedText() && control.textView.string == "candidate")
    }

    @Test func wheelRoutingOutsideTheCardFindsOnlyTheUnderlyingNativePage() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 800))
        let page = NSView(frame: NSRect(x: 200, y: 0, width: 800, height: 800))
        let document = NSView(frame: page.bounds)
        let card = NSView(frame: NSRect(x: 300, y: 450, width: 560, height: 120))
        root.addSubview(page)
        page.addSubview(document)
        root.addSubview(card)

        #expect(CommandBarScrollRouting.target(at: NSPoint(x: 900, y: 100), outside: card, in: page) === document)
        #expect(CommandBarScrollRouting.target(at: NSPoint(x: 400, y: 500), outside: card, in: page) == nil)
        #expect(CommandBarScrollRouting.target(at: NSPoint(x: 100, y: 100), outside: card, in: page) == nil)
        #expect(CommandBarScrollRouting.target(at: NSPoint(x: 1100, y: 100), outside: card, in: page) == nil)
        page.isHidden = true
        #expect(CommandBarScrollRouting.target(at: NSPoint(x: 900, y: 100), outside: card, in: page) == nil)
        page.isHidden = false
        page.removeFromSuperview()
        #expect(CommandBarScrollRouting.target(at: NSPoint(x: 500, y: 100), outside: card, in: page) == nil)
    }

    @Test func wheelRoutingUsesVisiblePageBoundsAndNeverStealsTheEditorsScroll() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 800))
        let clip = NSView(frame: NSRect(x: 200, y: 0, width: 600, height: 400))
        clip.clipsToBounds = true
        let page = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 800))
        let card = NSView(frame: NSRect(x: 300, y: 150, width: 400, height: 120))
        root.addSubview(clip)
        clip.addSubview(page)
        root.addSubview(card)
        #expect(CommandBarScrollRouting.target(at: NSPoint(x: 750, y: 100), outside: card, in: page) === page)
        #expect(CommandBarScrollRouting.target(at: NSPoint(x: 900, y: 100), outside: card, in: page) == nil)
        #expect(CommandBarScrollRouting.target(at: NSPoint(x: 750, y: 600), outside: card, in: page) == nil)
        #expect(CommandBarScrollRouting.target(at: NSPoint(x: 500, y: 200), outside: card, in: page) == nil)
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

    @Test func rightArrowFillsTheSelectedSuggestionWithoutSubmittingAndKeepsUndo() {
        let control = makeControl()
        defer { control.invalidate() }
        var publications = [String]()
        var submits = 0
        var cancellations = 0
        var suggestion: String? = "early browser 🦊"
        control.onTextChange = { publications.append($0); suggestion = nil }
        control.onCompleteSuggestion = { suggestion }
        control.onSubmit = { submits += 1 }
        control.onCancel = { cancellations += 1 }
        control.updateText("ear")
        // Explicitly selected results can complete even if the insertion point
        // was in the middle of the original input rather than at its end.
        control.textView.setSelectedRange(NSRange(location: 1, length: 0))

        #expect(control.handleCommand(#selector(NSResponder.moveRight(_:)), modifiers: [.function, .numericPad]))
        #expect(control.textView.string == "early browser 🦊")
        #expect(control.textView.selectedRange() == NSRange(location: ("early browser 🦊" as NSString).length, length: 0))
        #expect(publications == ["early browser 🦊"])
        #expect(submits == 0 && cancellations == 0)
        #expect(control.textView.undoManager?.canUndo == true)
        // Completion consumed the selection: subsequent arrows edit normally.
        #expect(!control.handleCommand(#selector(NSResponder.moveRight(_:))))

        control.textView.undoManager?.undo()
        #expect(control.textView.string == "ear")
        control.textView.undoManager?.redo()
        #expect(control.textView.string == "early browser 🦊")
        control.textView.insertText(" test", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(control.textView.string == "early browser 🦊 test")
        #expect(submits == 0 && cancellations == 0)
    }

    @Test func rightArrowWithoutASelectedSuggestionAndModifiedArrowsStayNative() {
        let control = makeControl()
        defer { control.invalidate() }
        control.updateText("existing text")
        let selection = NSRange(location: 2, length: 5)
        control.textView.setSelectedRange(selection)
        #expect(!control.handleCommand(#selector(NSResponder.moveRight(_:))))
        #expect(control.textView.selectedRange() == selection)

        var completions = 0
        control.onCompleteSuggestion = { completions += 1; return "must not replace" }
        for flags: NSEvent.ModifierFlags in [.shift, .option, .command, .control, [.shift, .option]] {
            #expect(!control.handleCommand(#selector(NSResponder.moveRight(_:)), modifiers: flags))
        }
        #expect(!control.handleCommand(#selector(NSResponder.moveRightAndModifySelection(_:)), modifiers: .shift))
        #expect(!control.handleCommand(#selector(NSResponder.moveWordRight(_:)), modifiers: .option))
        #expect(completions == 0)
        #expect(control.textView.string == "existing text")
        #expect(control.textView.selectedRange() == selection)

        control.invalidate()
        #expect(!control.handleCommand(#selector(NSResponder.moveRight(_:))))
        #expect(completions == 0)
    }

    @Test func longSuggestionCompletionWrapsAndScrollsWithItsCaretAtTheEnd() throws {
        let control = makeControl(width: 100, maxHeight: 72)
        defer { control.invalidate() }
        control.frame.size.height = 72
        control.updateText("early")
        let suggestion = String(repeating: "early browser ", count: 14)
        control.onCompleteSuggestion = { suggestion }
        #expect(control.handleCommand(#selector(NSResponder.moveRight(_:))))
        #expect(control.textView.string == suggestion)
        #expect(control.measuredHeight == 72)
        #expect(control.scrollView.hasVerticalScroller)
        #expect(control.textView.selectedRange() == NSRange(location: (suggestion as NSString).length, length: 0))
        let manager = try #require(control.textView.layoutManager)
        let container = try #require(control.textView.textContainer)
        let lastGlyph = NSRange(location: manager.numberOfGlyphs - 1, length: 1)
        let bottom = manager.boundingRect(forGlyphRange: lastGlyph, in: container).maxY
        #expect(control.scrollView.documentVisibleRect.maxY >= bottom - 1)
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
        control.onCompleteSuggestion = { browserCommands += 1; return "must not replace candidate" }

        control.textView.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(control.isComposing)
        #expect(control.textView.hasMarkedText())
        #expect(events.first == "composition began")
        #expect(!control.handleCommand(#selector(NSResponder.insertNewline(_:))))
        #expect(!control.handleCommand(#selector(NSResponder.cancelOperation(_:))))
        #expect(!control.handleCommand(#selector(NSResponder.moveDown(_:))))
        #expect(!control.handleCommand(#selector(NSResponder.moveRight(_:))))
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
