import Observation
import ReviewRuntime
import SwiftUI

@MainActor
@Observable
final class ReviewMonitorUIState {
    var selectedJobEntry: CodexReviewJob?
    var sidebarSelection = SidebarPickerSelection.workspace
}

enum SidebarPickerSelection: CaseIterable, Hashable {
    case workspace
    case account

    var localized: LocalizedStringResource {
        switch self {
        case .workspace:
            "Workspace"
        case .account:
            "Account"
        }
    }

    var systemImage: String {
        switch self {
        case .workspace:
            "folder"
        case .account:
            "person"
        }
    }
}
