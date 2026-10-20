// SPDX-License-Identifier: MPL-2.0

import EarlyCore
import Testing

@Suite struct PageLifecycleTests {
    @Test func presentationAndLoadingAreIndependentOfAllocation() {
        var page = PageLifecycle()
        #expect(page.state == .unloaded && !page.ownsView)
        #expect(page.setPresentation(visible: true, focused: true) == true)
        #expect(page.state == .unloaded && !page.ownsView)
        #expect(page.transition(.allocate) == true)
        #expect(page.state == .active && page.ownsView)
        #expect(page.transition(.allocate) == false)
        #expect(page.transition(.startLoading) == true)
        #expect(page.setPresentation(visible: false, focused: false) == true)
        #expect(page.state == .loading && !page.isVisible)
        #expect(page.transition(.finishLoading) == true)
        #expect(page.state == .background)
        #expect(page.setPresentation(visible: true, focused: false) == true)
        #expect(page.state == .active && !page.isFocused)
    }

    @Test func failureAndRetryKeepTheirVisibilityAndViewOwnership() {
        var page = PageLifecycle()
        page.transition(.allocate)
        page.transition(.startLoading)
        #expect(page.transition(.fail) == true)
        #expect(page.state == .failed && page.ownsView)
        page.setPresentation(visible: true, focused: true)
        #expect(page.state == .failed)
        #expect(page.transition(.finishLoading) == false)
        #expect(page.transition(.startLoading) == true)
        #expect(page.transition(.stopLoading) == true)
        #expect(page.state == .active)
    }

    @Test func suspensionHooksProtectVisibleAndLoadingPages() {
        var page = PageLifecycle()
        page.transition(.allocate)
        page.setPresentation(visible: true, focused: true)
        #expect(page.transition(.suspend) == false)
        page.setPresentation(visible: false, focused: false)
        page.transition(.startLoading)
        #expect(page.transition(.suspend) == false)
        page.transition(.finishLoading)
        #expect(page.transition(.suspend) == true)
        #expect(page.state == .suspended && page.ownsView)
        #expect(page.transition(.startLoading) == false)
        page.setPresentation(visible: true, focused: true)
        #expect(page.state == .suspended)
        #expect(page.transition(.resume) == true)
        #expect(page.state == .active)
    }

    @Test func discardedViewsCannotBeResurrectedByLateEvents() {
        var page = PageLifecycle()
        for event: PageLifecycle.Event in [.startLoading, .finishLoading, .stopLoading, .fail, .suspend, .resume] {
            #expect(page.transition(event) == false)
        }
        page.transition(.allocate)
        page.transition(.startLoading)
        #expect(page.transition(.discard) == true)
        #expect(page.state == .discarded && !page.ownsView)
        for event: PageLifecycle.Event in [.startLoading, .finishLoading, .stopLoading, .fail, .resume, .discard] {
            #expect(page.transition(event) == false)
        }
        #expect(page.transition(.allocate) == true, "Only explicit allocation can replace a discarded view")
        #expect(page.state == .background)
    }

    @Test func invalidFocusIsRejectedWithoutChangingPresentation() {
        var page = PageLifecycle()
        let before = page
        #expect(page.setPresentation(visible: false, focused: true) == false)
        #expect(page == before)
    }
}
