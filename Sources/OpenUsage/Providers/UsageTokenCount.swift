import Foundation

/// Bounds external log numbers before integer conversion and bucket summation.
enum UsageTokenCount {
    static let maximum = 1_000_000_000_000

    static func read(_ value: Any?, provider: String) -> Int {
        guard let value else { return 0 }
        guard let number = ProviderParse.number(value), number >= 0 else {
            AppLog.warn(LogTag.plugin(provider), "Ignored an invalid token count in a local usage record")
            return 0
        }
        guard number <= Double(maximum) else {
            AppLog.warn(LogTag.plugin(provider), "Clamped an implausible token count in a local usage record")
            return maximum
        }
        return Int(number)
    }
}
