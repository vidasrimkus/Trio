import CryptoKit
import Foundation

/// Pure rules for the remote `set_basal_schedule` command: validation, schedule hash, daily total and the
/// pre-checks. No pump or storage access here, so every rule is unit-tested.
enum RemoteBasalSchedule {
    /// Which pump manager is connected, as far as this command cares.
    enum PumpKind: Equatable {
        case dana
        case omnipod
        case other
        case none
    }

    /// One segment as sent by the remote side.
    struct Segment: Decodable, Equatable, Sendable {
        let start: String // "HH:mm", whole hours only
        let rate: Decimal // U/h
    }

    enum Rejection: Error, Equatable {
        case message(String)

        var text: String {
            switch self {
            case let .message(text): return text
            }
        }
    }

    static let maxSegments = 24
    static let maxNameLength = 30

    static let omnipodRejection =
        "Remote basal schedule change is not supported with Omnipod DASH: the pod briefly stops all delivery, and if the connection dropped it could not be resumed without the phone. Change it on the phone."

    static let partialWriteMessage =
        "Pompa galėjo priimti dalį pakeitimų. Pakartokite tą patį aktyvavimą arba patikrinkite pompą."

    // MARK: - Pre-checks

    /// Refuses unless a Dana is connected and idle. Nothing is queued: the sender simply retries.
    static func precheck(pump: PumpKind, suspended: Bool, bolusing: Bool, looping: Bool) -> Rejection? {
        switch pump {
        case .omnipod: return .message(omnipodRejection)
        case .none: return .message("No pump is connected.")
        case .other: return .message("Remote basal schedule change is supported only with a Dana pump.")
        case .dana: break
        }
        if suspended { return .message("The pump is suspended. Resume it on the phone first.") }
        if bolusing { return .message("A bolus is in progress. Try again when it has finished.") }
        if looping { return .message("A loop cycle is running. Try again in a minute.") }
        return nil
    }

    // MARK: - Validation

    /// Checks the name and the segments and returns the schedule in Trio's storage format.
    /// - supportedRates: the pump manager's `supportedBasalRates` (U/h).
    /// - danaEncoding: reject rates the Dana would store differently (`UInt16(rate * 100)` truncation).
    static func validate(
        name: String,
        segments: [Segment],
        supportedRates: [Double],
        maxBasal: Decimal,
        danaEncoding: Bool
    ) -> Result<[BasalProfileEntry], Rejection> {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.count <= maxNameLength else {
            return .failure(.message("Schedule name must be 1–\(maxNameLength) characters."))
        }
        guard !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || $0 == "\"" }) else {
            return .failure(.message("Schedule name must not contain quotes or control characters."))
        }
        guard !segments.isEmpty, segments.count <= maxSegments else {
            return .failure(.message("A schedule needs 1–\(maxSegments) segments."))
        }

        let supportedCents = Set(supportedRates.map { Int(($0 * 100).rounded()) }.filter { $0 > 0 })
        var entries: [BasalProfileEntry] = []
        var previousMinutes = -1

        for segment in segments {
            guard let hour = wholeHour(segment.start) else {
                return .failure(.message("\(segment.start): segments must start on a whole hour (HH:00)."))
            }
            let minutes = hour * 60
            if entries.isEmpty, minutes != 0 {
                return .failure(.message("The first segment must start at 00:00."))
            }
            guard minutes > previousMinutes else {
                return .failure(.message("\(segment.start): segment times must be strictly increasing."))
            }
            previousMinutes = minutes

            let rate = segment.rate
            guard rate > 0 else { return .failure(.message("\(segment.start): rate must be above 0 U/h.")) }
            guard rate <= maxBasal else {
                return .failure(.message("\(segment.start): \(rate) U/h is above Max Basal \(maxBasal) U/h."))
            }
            guard let cents = exactCents(rate), supportedCents.contains(cents) else {
                return .failure(.message("\(segment.start): \(rate) U/h is not a rate this pump supports."))
            }
            if danaEncoding {
                // The same Decimal → Double path the pump write takes (BasalProfileEditor.Provider), then
                // DanaKit's encoding.
                let stored = Int(UInt16(Double(rate) * 100))
                guard stored == cents else {
                    let storedRate = Decimal(stored) / 100
                    return .failure(.message("\(segment.start): \(rate) U/h would be stored as \(storedRate) U/h on the Dana. Use another rate."))
                }
            }
            entries.append(BasalProfileEntry(start: String(format: "%02d:00:00", hour), minutes: minutes, rate: rate))
        }
        return .success(entries)
    }

    /// "HH:mm" with mm == 00 → HH (0...23); anything else → nil.
    static func wholeHour(_ start: String) -> Int? {
        let parts = start.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].count == 2, parts[1] == "00",
              let hour = Int(parts[0]), (0 ... 23).contains(hour)
        else { return nil }
        return hour
    }

    /// The rate in hundredths of a unit when it is a whole number of hundredths, else nil.
    static func exactCents(_ rate: Decimal) -> Int? {
        var scaled = rate * 100
        var rounded = Decimal()
        NSDecimalRound(&rounded, &scaled, 0, .plain)
        guard rounded == scaled else { return nil }
        return NSDecimalNumber(decimal: rounded).intValue
    }

    // MARK: - Hash and daily total

    /// Identifies a schedule independently of how it is formatted. Canonical form: for every entry in
    /// start order `"<minutes from midnight>:<rate in hundredths>"`, joined with ";"; hash = lowercase hex of
    /// the first 8 bytes of SHA-256 over its UTF-8 bytes. LoopFollow computes the same (vectors in
    /// CUSTOMIZATIONS.md).
    static func hash(_ entries: [BasalProfileEntry]) -> String {
        let canonical = entries
            .sorted { $0.minutes < $1.minutes }
            .map { entry -> String in
                var scaled = entry.rate * 100
                var rounded = Decimal()
                NSDecimalRound(&rounded, &scaled, 0, .plain)
                return "\(entry.minutes):\(NSDecimalNumber(decimal: rounded).intValue)"
            }
            .joined(separator: ";")
        return SHA256.hash(data: Data(canonical.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// Units per day the schedule delivers.
    static func dailyTotal(_ entries: [BasalProfileEntry]) -> Decimal {
        let sorted = entries.sorted { $0.minutes < $1.minutes }
        var total: Decimal = 0
        for (index, entry) in sorted.enumerated() {
            let end = index + 1 < sorted.count ? sorted[index + 1].minutes : 24 * 60
            total += entry.rate * Decimal(end - entry.minutes) / 60
        }
        return total
    }
}
