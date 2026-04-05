import SwiftUI
import CodexReviewModel

@available(macOS 26.0, *)
struct ReviewMonitorAuthSheet: View {
    let auth: CodexReviewAuthModel
    @Environment(\.openURL) private var openURL
    @State private var openedBrowserURL: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(progress?.title ?? "Sign in to ReviewMCP")
                .font(.title2.weight(.semibold))

            if let detail = progress?.detail {
                Text(detail)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    Task {
                        await auth.cancelAuthentication()
                    }
                }
            }
        }
        .padding(24)
        .frame(minWidth: 480)
        .task(id: progress?.browserURL) {
            guard let browserURL = progress?.browserURL,
                  openedBrowserURL != browserURL,
                  let url = URL(string: browserURL)
            else {
                return
            }
            openedBrowserURL = browserURL
            openURL(url)
        }
    }

    private var progress: CodexReviewAuthModel.Progress? {
        auth.progress
    }
}
