import SwiftUI
import CodexReviewModel

@available(macOS 26.0, *)
public struct ReviewMonitorContentView: View {
    let store: CodexReviewStore

    public init(store: CodexReviewStore) {
        self.store = store
    }

    public var body: some View {
        ReviewMonitorSplitViewRepresentable(store: store)
            .ignoresSafeArea()
    }
}

#if DEBUG
#Preview {
    if #available(macOS 26.0, *) {
        ReviewMonitorContentView(store: ReviewMonitorPreviewContent.makeStore())
    }
}
#endif
