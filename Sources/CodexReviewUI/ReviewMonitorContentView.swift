import SwiftUI
import CodexReviewModel

public struct ReviewMonitorContentView: View {
    let store: CodexReviewStore

    public init(store: CodexReviewStore) {
        self.store = store
    }

    public var body: some View {
        ReviewMonitorSplitViewRepresentable(store: store)
    }
}

#if DEBUG
#Preview {
    ReviewMonitorContentView(store: ReviewMonitorPreviewContent.makeStore())
}
#endif
