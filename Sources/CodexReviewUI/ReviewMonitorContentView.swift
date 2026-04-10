import SwiftUI
import CodexReviewModel

#if DEBUG
@available(macOS 26.0, *)
@MainActor
private struct ReviewMonitorPreviewView: NSViewControllerRepresentable {
    var authState: CodexReviewAuthModel.State = .signedIn(accountID: "review@example.com")
    var serverState: CodexReviewServerState = .running

    func makeNSViewController(context: Context) -> NSViewController {
        makeReviewMonitorPreviewContentViewControllerForPreview(
            authState: authState,
            serverState: serverState
        )
    }

    func updateNSViewController(_ nsViewController: NSViewController, context: Context) {
    }
}

@available(macOS 26.0, *)
#Preview("Normal") {
    ReviewMonitorPreviewView()
}

@available(macOS 26.0, *)
#Preview("Server Failed") {
    ReviewMonitorPreviewView(
        serverState: .failed("The embedded server stopped responding.")
    )
}
#endif
