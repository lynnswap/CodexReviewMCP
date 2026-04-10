import SwiftUI
import CodexReviewModel

#if DEBUG
@available(macOS 26.0, *)
@MainActor
private struct ReviewMonitorPreviewView: NSViewControllerRepresentable {
    let store: CodexReviewStore

    func makeNSViewController(context: Context) -> ReviewMonitorSplitViewController {
        ReviewMonitorSplitViewController(store: store)
    }

    func updateNSViewController(_ nsViewController: ReviewMonitorSplitViewController, context: Context) {
    }
}

#Preview {
    if #available(macOS 26.0, *) {
        ReviewMonitorPreviewView(store: ReviewMonitorPreviewContent.makeStore())
            .frame(height:1000)
    }
}
#endif
