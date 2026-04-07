import SwiftUI
import CodexReviewMCP
@_spi(PreviewSupport) import CodexReviewUI

struct ContentView: View {
    let store: CodexReviewStore

    var body: some View {
        ReviewMonitorContentView(store: store)
    }
}

#Preview("Review Monitor") {
    ContentView(store: ReviewMonitorPreviewContent.makeStore())
}
