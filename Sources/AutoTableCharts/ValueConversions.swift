import Foundation

/// A domain value that can be represented without losing its source semantics.
public protocol AutoChartValueConvertible: Sendable {
    var autoChartValue: AutoChartValue { get }
}

extension AutoChartValue: AutoChartValueConvertible {
    public var autoChartValue: AutoChartValue { self }
}

extension Optional: AutoChartValueConvertible where Wrapped: AutoChartValueConvertible {
    public var autoChartValue: AutoChartValue {
        switch self {
        case .some(let value): value.autoChartValue
        case .none: .null
        }
    }
}

extension Bool: AutoChartValueConvertible {
    public var autoChartValue: AutoChartValue { .boolean(self) }
}

extension Int: AutoChartValueConvertible {
    public var autoChartValue: AutoChartValue { .integer(Int64(self)) }
}

extension Int8: AutoChartValueConvertible {
    public var autoChartValue: AutoChartValue { .integer(Int64(self)) }
}

extension Int16: AutoChartValueConvertible {
    public var autoChartValue: AutoChartValue { .integer(Int64(self)) }
}

extension Int32: AutoChartValueConvertible {
    public var autoChartValue: AutoChartValue { .integer(Int64(self)) }
}

extension Int64: AutoChartValueConvertible {
    public var autoChartValue: AutoChartValue { .integer(self) }
}

private func autoChartUnsignedValue<T: UnsignedInteger>(_ value: T) -> AutoChartValue {
    if let integer = Int64(exactly: value) {
        return .integer(integer)
    }
    // Decimal has enough precision for every standard-library unsigned integer.
    return .decimal(Decimal(string: String(value), locale: Locale(identifier: "en_US_POSIX"))!)
}

extension UInt: AutoChartValueConvertible {
    public var autoChartValue: AutoChartValue { autoChartUnsignedValue(self) }
}

extension UInt8: AutoChartValueConvertible {
    public var autoChartValue: AutoChartValue { autoChartUnsignedValue(self) }
}

extension UInt16: AutoChartValueConvertible {
    public var autoChartValue: AutoChartValue { autoChartUnsignedValue(self) }
}

extension UInt32: AutoChartValueConvertible {
    public var autoChartValue: AutoChartValue { autoChartUnsignedValue(self) }
}

extension UInt64: AutoChartValueConvertible {
    public var autoChartValue: AutoChartValue { autoChartUnsignedValue(self) }
}

extension Float: AutoChartValueConvertible {
    public var autoChartValue: AutoChartValue { .double(Double(self)) }
}

extension Double: AutoChartValueConvertible {
    public var autoChartValue: AutoChartValue { .double(self) }
}

extension Decimal: AutoChartValueConvertible {
    public var autoChartValue: AutoChartValue { .decimal(self) }
}

extension String: AutoChartValueConvertible {
    public var autoChartValue: AutoChartValue { .text(self) }
}

extension Substring: AutoChartValueConvertible {
    public var autoChartValue: AutoChartValue { .text(String(self)) }
}

extension Date: AutoChartValueConvertible {
    public var autoChartValue: AutoChartValue { .date(self) }
}

extension Data: AutoChartValueConvertible {
    public var autoChartValue: AutoChartValue { .binary(self) }
}
