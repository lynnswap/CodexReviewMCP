import Foundation
import SwiftUI
import ReviewRuntime

struct ReviewMonitorJobRowView: View {
    var job: CodexReviewJob

    var body: some View {
        LabeledContent {
            elapsedTimeTextLabel
        } label: {
            Label {
                VStack {
                    HStack {
                        Text(job.displayTitle)
                        Spacer(minLength: 0)
                    }
                    HStack{
                        if let model = job.model{
                            Text(model)
                        }
                        if let lastAgentMessage = job.lastAgentMessage{
                            Text(lastAgentMessage)
                        }
                        Spacer(minLength: 0)
                    }
                    .textScale(.secondary)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
            } icon: {
                Group {
                    if job.status == .running {
                        ProgressView()
                    } else {
                        Image(systemName: "circle.fill")
                            .foregroundStyle(job.status.color)
                    }
                }
                .controlSize(.mini)
                .animation(.default, value: job.status)
            }
        }
    }
    @ViewBuilder
    private var elapsedTimeTextLabel:some View{
        if let startedAt = job.startedAt {
            if let endedAt = job.endedAt {
                elapsedTimeText(
                    startedAt: startedAt,
                    referenceDate: endedAt
                )
            } else {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    elapsedTimeText(
                        startedAt: startedAt,
                        referenceDate: context.date
                    )
                }
            }
        }
    }

    private func elapsedTimeText(startedAt: Date, referenceDate: Date) -> some View {
        let elapsedSeconds = max(0, referenceDate.timeIntervalSince(startedAt).rounded(.down))
        return Text(
            Duration.seconds(elapsedSeconds),
            format: .time(pattern: elapsedTimePattern(for: elapsedSeconds))
        )
        .monospacedDigit()
        .contentTransition(.numericText(value: elapsedSeconds))
        .animation(.default, value: elapsedSeconds)
    }

    private func elapsedTimePattern(for elapsedSeconds: TimeInterval) -> Duration.TimeFormatStyle.Pattern {
        elapsedSeconds >= 3600 ? .hourMinute : .minuteSecond
    }
}

extension CodexReviewJobStatus {
    var color: Color {
        switch self {
        case .queued, .running:
            .gray
        case .succeeded:
            .green
        case .failed:
            .red
        case .cancelled:
            .yellow
        }
    }
}

#if DEBUG
#Preview {
    @Previewable @State var store = ReviewMonitorPreviewContent.makeStore()
    NavigationSplitView {
        List {
            ForEach(store.workspaces, id: \.cwd) { workspace in
                Section(workspace.displayTitle) {
                    ForEach(workspace.jobs) { job in
                        ReviewMonitorJobRowView(job: job)
                    }
                }
            }
        }
        .frame(minWidth: 320)
    } detail: {
        ContentUnavailableView {
            Text(verbatim: "Preview")
        }
    }
}
#endif
