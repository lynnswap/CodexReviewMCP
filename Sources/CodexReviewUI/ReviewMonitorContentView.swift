import SwiftUI
import CodexReviewModel

#if DEBUG
@available(macOS 26.0, *)
@MainActor
private struct ReviewMonitorPreviewView: NSViewControllerRepresentable {

    func makeNSViewController(context: Context) -> NSViewController {
        makeReviewMonitorPreviewContentViewController()
    }

    func updateNSViewController(_ nsViewController: NSViewController, context: Context) {
    }
}

@available(macOS 26.0, *)
#Preview {
    ReviewMonitorPreviewView()
        .ignoresSafeArea()
        .presentedWindowStyle(.automatic)
        .presentedWindowToolbarStyle(.unified)
}
#endif
