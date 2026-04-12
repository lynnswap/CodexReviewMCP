import SwiftUI
import CodexReviewModel

#if DEBUG
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

#Preview("Normal") {
    ReviewMonitorPreviewView()
        .ignoresSafeArea()
}

#Preview("Server Failed") {
    ReviewMonitorPreviewView(
        serverState: .failed("The embedded server stopped responding.")
    )
    .ignoresSafeArea()
}
#endif
