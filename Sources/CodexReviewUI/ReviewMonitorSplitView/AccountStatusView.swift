//
//  AccountStatusView.swift
//  CodexReviewMCP
//
//  Created by Kazuki Nakashima on 2026/04/15.
//

import SwiftUI
import CodexReviewModel

struct AccountStatusView: View {
    var account: CodexAccount?

    var body: some View {
        Group {
            if let account{
                VStack {
                    if let sessionLimits = account.sessionLimits {
                        gaugeView("Session", window: sessionLimits)
                    }
                    if let weeklyLimits = account.weeklyLimits {
                        gaugeView("Weekly", window: weeklyLimits)
                    }
                }
                .gaugeStyle(.accessoryLinearCapacity)
            }else{
                ContentUnavailableView {
                    Text("Rate limits unavailable")
                } description: {
                    Text("Usage details haven't loaded yet.")
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: account)
    }

    @ViewBuilder
    private func gaugeView(
        _ name: LocalizedStringResource,
        window: CodexRateLimitWindow
    ) -> some View {
        Gauge(value: window.usedFraction) {
            HStack {
                Text(name)
                if let resetsAt = limitResetDate(for: window) {
                    Text(resetsAt, style: .offset)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Text(window.usedFraction, format: .percent.precision(.fractionLength(0)))
            }
        }
    }

    private func limitResetDate(for window: CodexRateLimitWindow?) -> Date? {
        guard let window,
              window.usedFraction >= 1
        else {
            return nil
        }
        return window.resetsAt
    }
}

#if DEBUG
#Preview {
    let store = makeStatusPreviewStore()
    return StatusView(store: store)
        .padding()
}

#endif
