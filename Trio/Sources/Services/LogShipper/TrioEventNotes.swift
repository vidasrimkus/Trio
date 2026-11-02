import Foundation

/// Events worth a Nightscout Note right away (the full log follows within a few minutes).
enum TrioEvent: Equatable {
    enum BolusKind: String {
        case smb
        case manual
        case external
    }

    /// A bolus removed from History. `delivered` is `true` for a finalized pump record,
    /// `false` for one still pending, nil when not applicable (external insulin).
    case bolusDeleted(id: String, amount: Decimal, kind: BolusKind, delivered: Bool?, at: Date)
    case bolusFailed(kind: BolusKind, error: String?)
    case pumpError(error: String)
}

/// One-line Note format, shared with t1d-monitor (`docs/log-ingest-spec.md`):
/// `[trio-event v1] <name> key=value …`. Values never contain spaces or `"`, except `err="…"`.
enum TrioEventNote {
    static let prefix = "[trio-event v1]"
    static let maxErrorLength = 120

    static func format(_ event: TrioEvent) -> String {
        switch event {
        case let .bolusDeleted(id, amount, kind, delivered, at):
            var fields = ["bolus_deleted", "id=\(id)", "amount=\(decimal(amount))", "kind=\(kind.rawValue)"]
            if let delivered {
                fields.append("delivered=\(delivered)")
            }
            fields.append("at=\(iso(at))")
            return "\(prefix) " + fields.joined(separator: " ")
        case let .bolusFailed(kind, error):
            var fields = ["bolus_failed", "kind=\(kind.rawValue)"]
            if let error {
                fields.append("err=\"\(sanitize(error))\"")
            }
            return "\(prefix) " + fields.joined(separator: " ")
        case let .pumpError(error):
            return "\(prefix) pump_error err=\"\(sanitize(error))\""
        }
    }

    /// Single line, no double quotes, at most `maxErrorLength` characters.
    static func sanitize(_ error: String) -> String {
        var text = error
            .replacingOccurrences(of: "\"", with: "'")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if text.count > maxErrorLength {
            text = String(text.prefix(maxErrorLength - 1)) + "…"
        }
        return text
    }

    private static func decimal(_ value: Decimal) -> String {
        NSDecimalNumber(decimal: value).description(withLocale: Locale(identifier: "en_US_POSIX"))
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    private static func iso(_ date: Date) -> String {
        isoFormatter.string(from: date)
    }
}

/// "Same key at most once per window." Pump errors repeat every loop while a pump is unreachable.
struct EventThrottle {
    let window: TimeInterval
    private var lastSent: [String: Date] = [:]

    init(window: TimeInterval) {
        self.window = window
    }

    mutating func allow(_ key: String, at now: Date = Date()) -> Bool {
        if let last = lastSent[key], now.timeIntervalSince(last) < window {
            return false
        }
        lastSent[key] = now
        return true
    }
}
