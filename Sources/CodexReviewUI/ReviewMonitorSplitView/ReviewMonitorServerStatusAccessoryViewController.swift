import AppKit
import SwiftUI
import CodexReviewModel

@available(macOS 26.0, *)
@MainActor
final class ReviewMonitorServerStatusAccessoryViewController: NSSplitViewItemAccessoryViewController {
    init(store: CodexReviewStore) {
        super.init(nibName: nil, bundle: nil)

        automaticallyAppliesContentInsets = true
        view = NSHostingView(rootView: StatusView(store: store))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }
}

@available(macOS 26.0, *)
private struct StatusView: View {
    let store: CodexReviewStore

    private var state: CodexReviewServerState {
        store.serverState
    }

    private var detailText: String? {
        if let failureMessage = state.failureMessage {
            return failureMessage
        }
        return store.serverURL?.absoluteString
    }

    var body: some View {
        Divider()
        Menu{
            if let url = store.serverURL {
                Text(url.absoluteString)
                Divider()
            }
            Button("Reset Server") {
                Task {
                    await store.restart()
                }
            }
            .disabled(state.isRestartAvailable == false)
        }label:{
            Label{
                VStack{
                    Text(state.displayText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let detailText {
                        Text(detailText)
                            .foregroundStyle(.secondary)
                            .textScale(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }icon: {
                Image(systemName: state.symbolName)
                    .foregroundStyle(state.color)
            }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 8)
    }
}

private extension CodexReviewServerState {
    var color: Color {
        switch self {
        case .stopped:
            .secondary
        case .starting:
            .blue
        case .running:
            .green
        case .failed:
            .red
        }
    }

    var symbolName: String {
        switch self {
        case .stopped:
            "stop.circle.fill"
        case .starting:
            "arrow.triangle.2.circlepath.circle.fill"
        case .running:
            "checkmark.circle.fill"
        case .failed:
            "exclamationmark.circle.fill"
        }
    }
}
