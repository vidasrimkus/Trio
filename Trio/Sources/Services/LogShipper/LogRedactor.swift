import Foundation

/// Removes secrets from log text before it leaves the phone. Applied to the decoded text only —
/// byte offsets always refer to the raw file.
///
/// Always redacted: the Dana pairing key and passkey exchange (`PeripheralManager.swift`), the APNS
/// device token (`TrioRemoteControl+APNS.swift`), query-string secrets and bearer tokens. Around a
/// pairing (a few lines before, the exchange after it) every `Data: <hex>` is redacted too, since
/// the pairing packets are spread over several lines; the rest of the batch keeps its packet
/// diagnostics.
enum LogRedactor {
    static let redacted = "[redacted]"
    static let redactedPairing = "[redacted:pairing]"
    /// Lines around a pairing marker whose packets are redacted.
    static let pairingLinesBefore = 20
    static let pairingLinesAfter = 150

    private struct Rule {
        let regex: NSRegularExpression
        let template: String

        init(_ pattern: String, _ template: String) {
            regex = try! NSRegularExpression(pattern: pattern)
            self.template = template
        }
    }

    private static let valueRules: [Rule] = [
        Rule(#"(pairingKey: )\S+"#, "$1\(redacted)"),
        Rule(#"((?:Sending pairing request|Sending Passkey check|Passkey request failed)[^\n]*?Data: )[0-9A-Fa-f]+"#, "$1\(redacted)"),
        Rule(#"(Device token updated: )\S+"#, "$1\(redacted)"),
        Rule(#"((?i:token|secret|api[-_]?secret|password|passkey|pin)=)[^&\s"']+"#, "$1\(redacted)"),
        Rule(#"((?i:authorization: bearer )|(?i:bearer ))[A-Za-z0-9._~+/=-]{8,}"#, "$1\(redacted)")
    ]

    private static let pairingMarkers = [
        "Sending pairing request",
        "processPairingRequest",
        "Passkey",
        "requesting pincode",
        "Requested pincode"
    ]

    private static let pairingHex = Rule(#"(Data: )[0-9A-Fa-f]{2,}"#, "$1\(redactedPairing)")

    static func redact(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        var inPairingWindow = [Bool](repeating: false, count: lines.count)

        var sinceMarker = Int.max
        for i in lines.indices {
            if isPairingMarker(lines[i]) {
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
            if isPairingMarker(lines[i]) {
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
                lines[i] = apply(rule, to: lines[i])
            }
            if inPairingWindow[i] {
                lines[i] = apply(pairingHex, to: lines[i])
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func isPairingMarker(_ line: String) -> Bool {
        pairingMarkers.contains(where: { line.contains($0) })
    }

    private static func apply(_ rule: Rule, to text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        return rule.regex.stringByReplacingMatches(in: text, range: range, withTemplate: rule.template)
    }
}
