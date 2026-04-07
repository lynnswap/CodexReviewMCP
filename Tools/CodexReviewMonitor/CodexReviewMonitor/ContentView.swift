import SwiftUI
import CodexReviewMCP
import CodexReviewUI

struct ContentView: View {
    let store: CodexReviewStore

    var body: some View {
        ReviewMonitorContentView(store: store)
            .background(.ultraThickMaterial)
    }
}
