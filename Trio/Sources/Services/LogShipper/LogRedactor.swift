import Foundation

/// Removes secrets from log text before it leaves the phone. Applied to the decoded text only —
/// byte offsets always refer to the raw file.
///
/// Always redacted: the Dana pairing keys in every form DanaKit logs them (`pairingKey:`,
/// `Pairing key:`, `random pairing key:`, `random sync key:` — DanaKit e157a86 `PeripheralManager.swift`
/// 328, 383, 414), the pairing/passkey packets, the APNS device token (`TrioRemoteControl+APNS.swift`),
/// query-string secrets and bearer tokens. Around a pairing (a few lines before, the exchange
/// after it) every packet dump (`Data:`, `Receiving data:`, `Encoded data:`, `decrypt data:`) is
/// redacted too; the rest of the batch keeps its packet diagnostics.
enum LogRedactor {
    static let redacted = "[redacted]"
    static let redactedPairing = "[redacted:pairing]"
    /// Lines around a pairing marker whose packets are redacted.
    static let pairingLinesBefore = 20
    static let pairingLinesAfter = 150

    private struct Rule {
        /// Cheap lowercase substring tests before the regex runs (almost every line fails them).
        let needles: [String]
        let regex: NSRegularExpression
        let template: String

        init(needles: [String], _ pattern: String, _ template: String) {
            self.needles = needles
            regex = try! NSRegularExpression(pattern: pattern)
            self.template = template
        }

        func apply(to line: String, lowercased: String) -> String {
            guard needles.contains(where: { lowercased.contains($0) }) else { return line }
            let range = NSRange(line.startIndex..., in: line)
            return regex.stringByReplacingMatches(in: line, range: range, withTemplate: template)
        }
    }

    private static let valueRules: [Rule] = [
        Rule(needles: ["pairing"], #"(?i)((?:random )?pairing ?key: )[0-9A-Za-z]+"#, "$1\(redacted)"),
        Rule(needles: ["sync key"], #"(?i)(random sync key: )[0-9A-Za-z]+"#, "$1\(redacted)"),
        Rule(needles: ["pairing request", "passkey"], #"(?i)((?:Sending pairing request|Sending Passkey check|Passkey request failed)[^\n]*?data: )[0-9A-Fa-f]+"#, "$1\(redacted)"),
        Rule(needles: ["device token"], #"(Device token updated: )\S+"#, "$1\(redacted)"),
        Rule(needles: ["token=", "secret=", "password=", "passkey=", "pin="], #"((?i:token|secret|api[-_]?secret|password|passkey|pin)=)[^&\s"']+"#, "$1\(redacted)"),
        Rule(needles: ["bearer "], #"((?i:authorization: bearer )|(?i:bearer ))[A-Za-z0-9._~+/=-]{8,}"#, "$1\(redacted)")
    ]

    private static let pairingMarkers = [
        "sending pairing request",
        "processpairingrequest",
        "passkey",
        "requesting pincode",
        "requested pincode",
        // Not "encryption keys": DanaKit logs "Setting encryption keys. Pairing key: …" on every
        // RSv3 connect (~500/day); the keys on that line are redacted by valueRules and the
        // packets after it are encrypted with them, so a window there would only blank diagnostics.
        "security keys"
    ]

    private static let pairingHex = Rule(needles: ["data: "], #"(?i)(data: )[0-9A-Fa-f]{2,}"#, "$1\(redactedPairing)")

    static func redact(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        let lowercased = lines.map { $0.lowercased() }
        var inPairingWindow = [Bool](repeating: false, count: lines.count)

        var sinceMarker = Int.max
        for i in lines.indices {
            if isPairingMarker(lowercased[i]) {
                sinceMarker = 0
            } else if sinceMarker != Int.max {
                sinceMarker += 1
            }
            if sinceMarker <= pairingLinesAfter {
                inPairingWindow[i] = true
            }
        }
        var untilMarker = Int.max
        for i in lines.indices.reversed() {
            if isPairingMarker(lowercased[i]) {
                untilMarker = 0
            } else if untilMarker != Int.max {
                untilMarker += 1
            }
            if untilMarker <= pairingLinesBefore {
                inPairingWindow[i] = true
            }
        }

        for i in lines.indices {
            for rule in valueRules {
                lines[i] = rule.apply(to: lines[i], lowercased: lowercased[i])
            }
            if inPairingWindow[i] {
                lines[i] = pairingHex.apply(to: lines[i], lowercased: lowercased[i])
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func isPairingMarker(_ lowercasedLine: String) -> Bool {
        pairingMarkers.contains(where: { lowercasedLine.contains($0) })
    }
}
