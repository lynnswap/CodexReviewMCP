import Foundation

package enum JSONRPCRequestID: Sendable, Equatable, Hashable {
    case string(String)
    case integer(Int)
    case double(Double)

    package init?(jsonObject: Any) {
        if let string = jsonObject as? String {
            self = .string(string)
            return
        }
        if let integer = jsonObject as? Int {
            self = .integer(integer)
            return
        }
        if let double = jsonObject as? Double {
            if double.rounded(.towardZero) == double, let exact = Int(exactly: double) {
                self = .integer(exact)
            } else {
                self = .double(double)
            }
            return
        }
        if let number = jsonObject as? NSNumber {
            let doubleValue = number.doubleValue
            if doubleValue.rounded(.towardZero) == doubleValue, let exact = Int(exactly: doubleValue) {
                self = .integer(exact)
            } else {
                self = .double(doubleValue)
            }
            return
        }
        return nil
    }

    package var foundationObject: Any {
        switch self {
        case .string(let value):
            value
        case .integer(let value):
            value
        case .double(let value):
            value
        }
    }
}
