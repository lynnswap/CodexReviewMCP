import SwiftUI
import CodexReviewModel

#if DEBUG
@MainActor
private struct ReviewMonitorPreviewView: NSViewControllerRepresentable {
    var authPhase: CodexReviewAuthModel.Phase = .signedOut
    var account: CodexAccount?
    var serverState: CodexReviewServerState = .running

    func makeNSViewController(context: Context) -> NSViewController {
        makeReviewMonitorPreviewContentViewControllerForPreview(
            authPhase: authPhase,
            account: account,
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
