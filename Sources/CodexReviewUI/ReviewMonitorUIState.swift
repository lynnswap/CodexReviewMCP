import Observation
import ReviewApp
import ReviewRuntime
import SwiftUI
import ReviewDomain

@MainActor
@Observable
final class ReviewMonitorUIState {
    let auth: CodexReviewAuthModel
    var selectedJobEntry: CodexReviewJob?
    var sidebarSelection = SidebarPickerSelection.workspace

    init(auth: CodexReviewAuthModel) {
        self.auth = auth
    }

    var presentedContentKind: ReviewMonitorContentKind?

    var contentKind: ReviewMonitorContentKind {
        if auth.selectedAccount != nil || auth.hasSavedAccounts {
            return .contentView
        }
        return .signInView
    }
}

enum ReviewMonitorContentKind: Equatable ,CaseIterable{
    case contentView
    case signInView
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
