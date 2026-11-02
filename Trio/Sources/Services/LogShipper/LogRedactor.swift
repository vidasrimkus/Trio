import Foundation

/// Removes secrets from log text before it leaves the phone. Applied to the decoded text only —
/// byte offsets always refer to the raw file.
///
/// Always redacted: the Dana pairing key and passkey exchange (`PeripheralManager.swift`), the APNS
/// device token (`TrioRemoteControl+APNS.swift`), query-string secrets and bearer tokens. When a chunk
/// contains a pairing, every `Data: <hex>` in it is redacted too, since the pairing packets are
/// spread over several lines.
enum LogRedactor {
    static let redacted = "[redacted]"
    static let redactedPairing = "[redacted:pairing]"

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
        var result = text
        for rule in valueRules {
            result = apply(rule, to: result)
        }
        if pairingMarkers.contains(where: { result.contains($0) }) {
            result = apply(pairingHex, to: result)
        }
        return result
    }

    private static func apply(_ rule: Rule, to text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        return rule.regex.stringByReplacingMatches(in: text, range: range, withTemplate: rule.template)
    }
}
