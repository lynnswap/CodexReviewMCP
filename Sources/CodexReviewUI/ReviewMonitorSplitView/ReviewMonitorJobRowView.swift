import Foundation
import SwiftUI
import ReviewRuntime

struct ReviewMonitorJobRowView: View {
    var job: CodexReviewJob
    var onCancel: () -> Void = {}

    var body: some View {
        Label {
            VStack {
                HStack {
                    Text(job.displayTitle)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                    TimerLabelView(job:job)
                        .foregroundStyle(.secondary)
                        .layoutPriority(1)
                }
                .lineLimit(1)
                HStack{
                    if let model = job.model{
                        Text(model)
                    }
                    if let subtitle = subtitleText {
                        Text(subtitle)
                    }
                    Spacer(minLength: 0)
                }
                .textScale(.secondary)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        } icon: {
            ZStack {
                Image(systemName: "circle.fill")
                    .foregroundStyle(.clear)
                if job.status == .running {
                    ProgressView()
                        .controlSize(.mini)
                }
            }
            .animation(.default, value: job.status)
        }
        .transaction(value: job.id) { transaction in
            transaction.disablesAnimations = true
        }
        .contentShape(.rect)
        .contextMenu{
            Button(role: .cancel, action: onCancel) {
                Text("Cancel")
            }
            .disabled(job.isTerminal || job.cancellationRequested)
        }
    }

    private var subtitleText: String? {
        if job.hasFinalReview,
           let finalReview = job.lastAgentMessage?.trimmingCharacters(in: .whitespacesAndNewlines),
           finalReview.isEmpty == false
        {
            return finalReview
        }
        if job.status == .cancelled {
            let reviewText = job.reviewText.trimmingCharacters(in: .whitespacesAndNewlines)
            return reviewText.isEmpty ? nil : reviewText
        }
        if let errorMessage = job.errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines),
           errorMessage.isEmpty == false
        {
            let summary = job.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            return summary.isEmpty ? errorMessage : summary
        }
        guard let lastAgentMessage = job.lastAgentMessage?.trimmingCharacters(in: .whitespacesAndNewlines),
              lastAgentMessage.isEmpty == false
        else {
            return nil
        }
        return lastAgentMessage
    }

    
}
struct TimerLabelView:View{
    var job: CodexReviewJob
    var body:some View{
        if let startedAt = job.startedAt {
            Text(
                timerInterval: startedAt...(job.endedAt ?? .distantFuture),
                pauseTime: job.endedAt,
                countsDown: false,
                showsHours: true
            )
            .monospacedDigit()
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
        case .queued: .gray
        case .running: .clear
        case .succeeded: .green
        case .failed: .red
        case .cancelled: .yellow
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
                        NavigationLink{
                            
                        }label:{
                            ReviewMonitorJobRowView(job: job)
                        }
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
