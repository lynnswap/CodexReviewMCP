//
//  ContentView.swift
//  CodexReviewMonitor
//
//  Created by Kazuki Nakashima on 2026/03/28.
//

import SwiftUI
import CodexReviewMCP

struct ContentView: View {
    let store: CodexReviewMonitorStore

    var body: some View {
        ReviewMonitorSplitViewRepresentable(
            store: store,
            onRestart: {
                Task {
                    await store.restart()
                }
            }
        )
        .frame(minWidth: 960, minHeight: 640)
    }
}

#Preview {
    ContentView(store: CodexReviewMonitorStore())
}
