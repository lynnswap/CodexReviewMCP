import SwiftUI
import ReviewRuntime

struct ReviewMonitorJobRowView: View {
    var job: CodexReviewJob

    var body: some View {
        Label {
            VStack {
                HStack {
                    Text("Hello, World!")
                    Spacer(minLength: 0)
                }
                Text("Hello, World!")
                    .textScale(.secondary)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
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
        List(store.jobs) { job in
            ReviewMonitorJobRowView(job: job)
        }
        .frame(minWidth: 320)
    } detail: {
        ContentUnavailableView {
            Text(verbatim: "Preview")
        }
    }
}
#endif
