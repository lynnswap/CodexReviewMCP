import AppKit
import SwiftUI
import CodexReviewModel

@available(macOS 26.0, *)
struct ReviewMonitorAuthSheet: View {
    let auth: CodexReviewAuthModel
    @State private var openedBrowserURL: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(progress?.title ?? "Sign in to ReviewMCP")
                .font(.title2.weight(.semibold))

            if let detail = progress?.detail {
                Text(detail)
                    .foregroundStyle(.secondary)
            }

            if let userCode = progress?.userCode?.nilIfEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Code")
                        .font(.headline)
                    Text(userCode)
                        .font(.system(.title3, design: .monospaced).weight(.semibold))
                        .textSelection(.enabled)
                }
            }

            HStack {
                if let browserURL = progress?.browserURL,
                   let url = URL(string: browserURL)
                {
                    Button("Open Browser") {
                        openedBrowserURL = browserURL
                        NSWorkspace.shared.open(url)
                    }
                }
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
            NSWorkspace.shared.open(url)
        }
    }

    private var progress: CodexReviewAuthModel.Progress? {
        auth.progress
    }
}
