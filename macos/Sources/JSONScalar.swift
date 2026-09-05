import Foundation
import CoreFoundation

enum JSONScalar {
    /// Foundation bridges JSON numbers 0/1 to Bool, so `as? Bool` alone
    /// cannot enforce a boolean-only permission or configuration field.
    static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }
}
