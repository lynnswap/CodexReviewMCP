import Foundation

package struct ReviewStoreDependencies: Sendable {
    package var dateNow: @Sendable () -> Date
    package var uuid: @Sendable () -> UUID

    package init(
        dateNow: @escaping @Sendable () -> Date = { Date() },
        uuid: @escaping @Sendable () -> UUID = { UUID() }
    ) {
        self.dateNow = dateNow
        self.uuid = uuid
    }

    package static func live() -> Self {
        Self()
    }
}
