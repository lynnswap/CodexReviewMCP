import AppKit
import SwiftUI

@MainActor
final class ReviewMonitorSidebarSegmentedAccessoryViewController: NSSplitViewItemAccessoryViewController {
    init(uiState: ReviewMonitorUIState) {
        super.init(nibName: nil, bundle: nil)

        automaticallyAppliesContentInsets = true
        view = NSHostingView(rootView: SidebarPickerView(uiState: uiState))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }
}

struct SidebarPickerView: View {
    @Bindable var uiState: ReviewMonitorUIState

    var body: some View {
        Picker("Sidebar", selection: $uiState.sidebarSelection) {
            ForEach(SidebarPickerSelection.allCases, id: \.self) { selection in
                Label {
                    Text(selection.localized)
                } icon: {
                    Image(systemName: selection.systemImage)
                }
                    .tag(selection)
            }
        }
        .labelStyle(.iconOnly)
        .labelsHidden()
        .buttonSizing(.flexible)
        .controlSize(.large)
        .pickerStyle(.segmented)
    }
}

#if DEBUG
@MainActor
extension ReviewMonitorSidebarSegmentedAccessoryViewController {
    var segmentAccessibilityDescriptionsForTesting: [String] {
        SidebarPickerSelection.allCases.map {
            String(localized: $0.localized)
        }
    }
}
#endif
