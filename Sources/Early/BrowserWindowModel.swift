import EarlyCore
import Observation

@MainActor @Observable
final class BrowserWindowModel {
    let coordinator: BrowserCoordinator
    let webViews = WebViewManager()
    var submissionMessage: String?

    init(startup: StartupContext) {
        coordinator = BrowserCoordinator(startup: startup)
    }

    func presentCommandBar(_ intent: CommandBarIntent) {
        submissionMessage = nil
        coordinator.presentCommandBar(intent)
    }

    func submit() {
        guard coordinator.navigationRequest() != nil else { return }
        submissionMessage = "Browsing will be available in the next build."
    }

    func closeActiveTab() {
        if let id = coordinator.closeActiveTab() { webViews.discard(tabID: id) }
    }
}
