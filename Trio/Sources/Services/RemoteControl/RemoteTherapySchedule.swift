import CryptoKit
import Foundation
import UserNotifications

/// Pure rules for the remote `set_carb_ratios` and `set_isf` commands: validation, the 48 half-hour slots, the
/// shared hashes and the pre-check. No storage access here, so every rule is unit-tested. Contract and vectors:
/// CUSTOMIZATIONS.md §11.
enum RemoteTherapySchedule {
    /// One carb ratio entry as sent by the remote side.
    struct CarbRatioSegment: Decodable, Equatable, Sendable {
        let start: String // "HH:00" or "HH:30"
        let ratio: Decimal // g/U
    }

    /// One insulin sensitivity entry as sent by the remote side (always mg/dL).
    struct SensitivitySegment: Decodable, Equatable, Sendable {
        let start: String // "HH:00" or "HH:30"
        let sensitivity: Decimal // integer mg/dL per U
    }

    typealias Rejection = RemoteBasalSchedule.Rejection

    static let maxEntries = 48
    static let maxNameLength = 30
    /// Carb Ratio editor grid: 1.0 … 50.0 g/U, step 0.1.
    static let minCarbRatio: Decimal = 1
    static let maxCarbRatio: Decimal = 50
    /// ISF editor picker: 9 … 540 mg/dL, step 1.
    static let minSensitivity: Decimal = 9
    static let maxSensitivity: Decimal = 540

    // MARK: - Pre-check

    /// Refuses while a loop cycle runs. Nothing is queued: the sender simply retries. No pump check — CR and ISF
    /// are Trio-only settings, nothing is written to the pump.
    static func precheck(looping: Bool) -> Rejection? {
        looping ? .message("A loop cycle is running. Try again in a minute.") : nil
    }

    // MARK: - Decision (the handler's steps 1–5, pure)

    /// What the handler does after the checks. Every `.failure` text is passed unchanged to
    /// `logError(_:payload:)`, i.e. it is the message LoopFollow receives.
    enum Plan<Entry> {
        case alreadyActive(name: String, hash: String)
        case write(name: String, entries: [Entry], activeHash: String, newHash: String)
    }

    static func rejected(_ reason: String) -> Rejection { .message("Command rejected: \(reason)") }

    /// Steps 1–5 for `set_carb_ratios`. `stored` is read only after the payload is valid.
    static func planCarbRatios(
        schedule: [CarbRatioSegment]?,
        name: String?,
        expectedHash: String?,
        looping: Bool,
        stored: () -> [CarbRatioEntry]
    ) -> Result<Plan<CarbRatioEntry>, Rejection> {
        guard let schedule, let name, let expectedHash else {
            return .failure(rejected("carb ratio schedule data is incomplete."))
        }
        if let rejection = precheck(looping: looping) { return .failure(rejected(rejection.text)) }
        let entries: [CarbRatioEntry]
        switch validateCarbRatios(name: name, segments: schedule) {
        case let .success(valid): entries = valid
        case let .failure(rejection): return .failure(rejected(rejection.text))
        }
        let current = stored()
        let activeHash = carbRatioHash(current)
        let newHash = carbRatioHash(entries)
        // Re-sending the schedule that is already in force is safe and changes nothing.
        guard carbRatioSlots(entries) != carbRatioSlots(current) else {
            return .success(.alreadyActive(name: name, hash: newHash))
        }
        guard expectedHash == activeHash else {
            return .failure(rejected(
                "the active carb ratios changed since they were read (expected \(expectedHash), active \(activeHash)). Refresh and try again."
            ))
        }
        if let rejection = changeRejection(old: carbRatioSlots(current), new: carbRatioSlots(entries), label: "CR", unit: "g/U") {
            return .failure(rejected(rejection.text))
        }
        return .success(.write(name: name, entries: entries, activeHash: activeHash, newHash: newHash))
    }

    /// Steps 1–5 for `set_isf`. `units` = the app's glucose units now (what Nightscout shows). `stored` is read only
    /// after the payload is valid.
    static func planSensitivities(
        schedule: [SensitivitySegment]?,
        name: String?,
        expectedHash: String?,
        looping: Bool,
        units: GlucoseUnits,
        stored: () -> [InsulinSensitivityEntry]
    ) -> Result<Plan<InsulinSensitivityEntry>, Rejection> {
        guard let schedule, let name, let expectedHash else {
            return .failure(rejected("ISF schedule data is incomplete."))
        }
        if let rejection = precheck(looping: looping) { return .failure(rejected(rejection.text)) }
        let entries: [InsulinSensitivityEntry]
        switch validateSensitivities(name: name, segments: schedule) {
        case let .success(valid): entries = valid
        case let .failure(rejection): return .failure(rejected(rejection.text))
        }
        if let rejection = mmolEditorRejection(entries, units: units) { return .failure(rejected(rejection.text)) }
        let current = stored()
        let activeHash = sensitivityNightscoutHash(current, units: units)
        let newHash = sensitivityNightscoutHash(entries, units: units)
        // Exact mg/dL comparison: the Nightscout form is lossy in mmol/L (46 and 47 mg/dL are both 2.6).
        guard sensitivitySlots(entries) != sensitivitySlots(current) else {
            return .success(.alreadyActive(name: name, hash: newHash))
        }
        guard expectedHash == activeHash else {
            return .failure(rejected(
                "the active ISF changed since it was read (expected \(expectedHash), active \(activeHash)). Refresh and try again."
            ))
        }
        if let rejection = changeRejection(old: sensitivitySlots(current), new: sensitivitySlots(entries), label: "ISF", unit: "mg/dL") {
            return .failure(rejected(rejection.text))
        }
        return .success(.write(name: name, entries: entries, activeHash: activeHash, newHash: newHash))
    }

    /// Exact Decimal comparison on all 48 slots; no display rounding, including in mmol/L mode.
    static func changeRejection(old: [Decimal], new: [Decimal], label: String, unit: String) -> Rejection? {
        guard old.count == 48, new.count == 48, old.allSatisfy({ $0 > 0 && !$0.isNaN }) else {
            return .message("Cannot verify the active schedule. Check Trio on the child's phone.")
        }
        for (slot, pair) in zip(old, new).enumerated() {
            let (before, after) = pair
            if abs(after - before) * 100 > before * 20 {
                let percent = Trio.rounded((after - before) * 100 / before, scale: 2, roundingMode: .plain)
                return .message("\(label) \(storageStart(slot * 30).prefix(5)): \(before) → \(after) \(unit) (\(percent)%). Maksimalus pokytis vienu kartu yra ±20 %.")
            }
        }
        return nil
    }

    static func changeSummary(old: [Decimal], new: [Decimal]) -> String {
        guard old.count == 48, new.count == 48 else { return "Grafikas atkurtas." }
        var lines: [String] = []
        for slot in 0 ..< 48 where old[slot] != new[slot] {
            if slot > 0, old[slot] == old[slot - 1], new[slot] == new[slot - 1] { continue }
            lines.append("\(storageStart(slot * 30).prefix(5)) \(old[slot]) → \(new[slot])")
        }
        return lines.joined(separator: "; ")
    }

    // MARK: - mmol/L editor values

    /// The smallest mg/dL in `minSensitivity…mgdl` with the same `asMmolL` (0.1 mmol/L group) as `mgdl`. In mmol/L
    /// mode Trio's ISF editor offers only these values (PickerSettingsProvider.generatePickerValues keeps the first,
    /// i.e. smallest, mg/dL of each group).
    static func smallestMgdlInMmolGroup(_ mgdl: Decimal) -> Decimal {
        let group = mgdl.asMmolL
        var smallest = mgdl
        while smallest - 1 >= minSensitivity, (smallest - 1).asMmolL == group {
            smallest -= 1
        }
        return smallest
    }

    /// In mmol/L mode, refuses a sensitivity the editor could not show (and would silently rewrite on the next save
    /// on the phone). Runs after validation, so every value is an integer in 9…540. No rule in mg/dL mode.
    static func mmolEditorRejection(_ entries: [InsulinSensitivityEntry], units: GlucoseUnits) -> Rejection? {
        guard units == .mmolL else { return nil }
        for entry in entries {
            let smallest = smallestMgdlInMmolGroup(entry.sensitivity)
            if smallest != entry.sensitivity {
                return .message(
                    "\(entry.start.prefix(5)): ISF \(entry.sensitivity) mg/dL is not a value Trio's mmol/L ISF editor can show (use \(smallest))."
                )
            }
        }
        return nil
    }

    // MARK: - Storage form

    /// The file the ISF editor writes: always mg/dL, whatever the app's display units (the editor's own save).
    static func sensitivityProfile(_ entries: [InsulinSensitivityEntry]) -> InsulinSensitivities {
        InsulinSensitivities(units: .mgdL, userPreferredUnits: .mgdL, sensitivities: entries)
    }

    /// The value Nightscout gets for one stored mg/dL ISF (NightscoutManager.uploadProfiles): unchanged in mg/dL,
    /// `asMmolL` in mmol/L.
    static func nightscoutSensitivity(_ mgdl: Decimal, units: GlucoseUnits) -> Decimal {
        units == .mgdL ? mgdl : mgdl.asMmolL
    }

    // MARK: - Validation

    /// Checks the name and the entries and returns the schedule in Trio's storage format (as the editor saves it).
    static func validateCarbRatios(name: String, segments: [CarbRatioSegment]) -> Result<[CarbRatioEntry], Rejection> {
        if let rejection = validateName(name) { return .failure(rejection) }
        let minutes: [Int]
        switch validateStarts(segments.map(\.start)) {
        case let .success(valid): minutes = valid
        case let .failure(rejection): return .failure(rejection)
        }
        var entries: [CarbRatioEntry] = []
        for (segment, minute) in zip(segments, minutes) {
            let ratio = segment.ratio
            guard ratio >= minCarbRatio, ratio <= maxCarbRatio else {
                return .failure(.message("\(segment.start): carb ratio \(ratio) g/U is outside \(minCarbRatio)–\(maxCarbRatio) g/U."))
            }
            guard let tenths = exactUnits(ratio * 10) else {
                return .failure(.message("\(segment.start): carb ratio \(ratio) g/U must be a whole number of tenths."))
            }
            entries.append(CarbRatioEntry(start: storageStart(minute), offset: minute, ratio: Decimal(tenths) / 10))
        }
        return .success(entries)
    }

    /// Checks the name and the entries and returns the schedule in Trio's storage format (as the editor saves it).
    static func validateSensitivities(
        name: String,
        segments: [SensitivitySegment]
    ) -> Result<[InsulinSensitivityEntry], Rejection> {
        if let rejection = validateName(name) { return .failure(rejection) }
        let minutes: [Int]
        switch validateStarts(segments.map(\.start)) {
        case let .success(valid): minutes = valid
        case let .failure(rejection): return .failure(rejection)
        }
        var entries: [InsulinSensitivityEntry] = []
        for (segment, minute) in zip(segments, minutes) {
            let value = segment.sensitivity
            guard let mgdl = exactUnits(value) else {
                return .failure(.message("\(segment.start): ISF \(value) must be a whole number of mg/dL."))
            }
            guard value >= minSensitivity, value <= maxSensitivity else {
                return .failure(.message("\(segment.start): ISF \(value) mg/dL is outside \(minSensitivity)–\(maxSensitivity) mg/dL."))
            }
            entries.append(InsulinSensitivityEntry(sensitivity: Decimal(mgdl), offset: minute, start: storageStart(minute)))
        }
        return .success(entries)
    }

    /// Same rule as `basal_schedule_name`: 1–30 characters after trimming spaces, no quotes or control characters.
    static func validateName(_ name: String) -> Rejection? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.count <= maxNameLength else {
            return .message("Schedule name must be 1–\(maxNameLength) characters.")
        }
        guard !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || $0 == "\"" }) else {
            return .message("Schedule name must not contain quotes or control characters.")
        }
        return nil
    }

    /// 1–48 starts; the first at 00:00; each on the 30-minute grid; strictly increasing. Returns the minutes.
    static func validateStarts(_ starts: [String]) -> Result<[Int], Rejection> {
        guard !starts.isEmpty, starts.count <= maxEntries else {
            return .failure(.message("A schedule needs 1–\(maxEntries) entries."))
        }
        var result: [Int] = []
        for start in starts {
            guard let minutes = halfHourMinutes(start) else {
                return .failure(.message("\(start): entries must start on the hour or half hour (HH:00 or HH:30)."))
            }
            if result.isEmpty, minutes != 0 {
                return .failure(.message("The first entry must start at 00:00."))
            }
            if let previous = result.last, minutes <= previous {
                return .failure(.message("\(start): entry times must be strictly increasing."))
            }
            result.append(minutes)
        }
        return .success(result)
    }

    /// "HH:mm" with HH 00…23 and mm 00 or 30 → minutes from midnight; anything else → nil.
    static func halfHourMinutes(_ start: String) -> Int? {
        let parts = start.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].count == 2, parts[0].allSatisfy({ $0.isASCII && $0.isNumber }),
              parts[1] == "00" || parts[1] == "30",
              let hour = Int(parts[0]), (0 ... 23).contains(hour)
        else { return nil }
        return hour * 60 + (parts[1] == "30" ? 30 : 0)
    }

    /// "HH:MM:00", the start format the editors store. Starts are minutes from midnight in the phone's local time
    /// and are stored as received: no Date, Calendar or TimeZone is involved (the editors format with a fixed
    /// GMT formatter, which gives the same string).
    static func storageStart(_ minutes: Int) -> String {
        String(format: "%02d:%02d:00", minutes / 60, minutes % 60)
    }

    /// The value as an Int when it is a whole number, else nil.
    static func exactUnits(_ value: Decimal) -> Int? {
        let whole = roundHalfUp(value)
        guard whole == value else { return nil }
        return NSDecimalNumber(decimal: whole).intValue
    }

    // MARK: - Slots

    /// The value in force at each of the 48 half-hours 00:00, 00:30, … 23:30: the entry with the latest start at
    /// or before that time; before the first entry, the last entry (a daily schedule wraps). Empty → [].
    static func slots(_ entries: [(minutes: Int, value: Decimal)]) -> [Decimal] {
        let sorted = entries.sorted { $0.minutes < $1.minutes }
        guard let lastEntry = sorted.last else { return [] }
        return (0 ..< 48).map { slot in
            let minute = slot * 30
            return (sorted.last(where: { $0.minutes <= minute }) ?? lastEntry).value
        }
    }

    static func carbRatioSlots(_ entries: [CarbRatioEntry]) -> [Decimal] {
        slots(entries.map { (minutes: $0.offset, value: $0.ratio) })
    }

    /// mg/dL per slot, as stored.
    static func sensitivitySlots(_ entries: [InsulinSensitivityEntry]) -> [Decimal] {
        slots(entries.map { (minutes: $0.offset, value: $0.sensitivity) })
    }

    // MARK: - Hashes (shared with LoopFollow)

    /// `"cr;"` + 48 × (ratio × 10 rounded half-up), joined with ";".
    static func carbRatioHash(_ entries: [CarbRatioEntry]) -> String {
        hashOf(canonical: "cr;" + carbRatioSlots(entries).map { intText($0 * 10) }.joined(separator: ";"))
    }

    /// The hash of `sens` as Trio uploads it to Nightscout (NightscoutManager.uploadProfiles): mg/dL when the app
    /// shows mg/dL, else `asMmolL` (0.0555, one decimal, half-up). mg/dL: `"isf-mgdl;"` + 48 × round(value);
    /// mmol/L: `"isf-mmol;"` + 48 × round(asMmolL(value) × 10). Lossy in mmol/L (46 and 47 mg/dL are both 2.6),
    /// so it is used only as the "nothing changed since it was read" guard.
    static func sensitivityNightscoutHash(_ entries: [InsulinSensitivityEntry], units: GlucoseUnits) -> String {
        let values = sensitivitySlots(entries)
        switch units {
        case .mgdL:
            return hashOf(canonical: "isf-mgdl;" + values.map { intText($0) }.joined(separator: ";"))
        case .mmolL:
            return hashOf(
                canonical: "isf-mmol;" + values.map { intText(nightscoutSensitivity($0, units: .mmolL) * 10) }
                    .joined(separator: ";")
            )
        }
    }

    private static func roundHalfUp(_ value: Decimal) -> Decimal {
        Trio.rounded(value, scale: 0, roundingMode: .plain)
    }

    private static func intText(_ value: Decimal) -> String {
        "\(NSDecimalNumber(decimal: roundHalfUp(value)).intValue)"
    }

    private static func hashOf(canonical: String) -> String {
        SHA256.hash(data: Data(canonical.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

/// Keeps the complete original file, including entry boundaries, units and Decimal text.
/// Restore never replaces this snapshot, so retrying restore cannot toggle back to the changed schedule.
struct RemoteTherapyBackup: JSON {
    let rawProfile: String
    let savedAt: Date
    let exactHash: String

    init(rawProfile: String, savedAt: Date = Date()) {
        self.rawProfile = rawProfile
        self.savedAt = savedAt
        exactHash = Self.hash(rawProfile)
    }

    var isValid: Bool { exactHash == Self.hash(rawProfile) }

    static func hash(_ raw: String) -> String {
        SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func filename(_ profileFile: String) -> String { profileFile + ".remote-previous.json" }

    static func restoreRaw(file: String, storage: FileStorage, expectedHash: String?, activeHash: String, looping: Bool) -> Result<String, RemoteTherapySchedule.Rejection> {
        guard let expectedHash else { return .failure(.message("Command rejected: expected_active_hash is required.")) }
        if let rejection = RemoteTherapySchedule.precheck(looping: looping) { return .failure(rejection) }
        guard let backup = storage.retrieve(filename(file), as: RemoteTherapyBackup.self), backup.isValid else {
            return .failure(.message("Command rejected: no valid exact previous backup on Trio."))
        }
        if storage.retrieveRaw(file) != backup.rawProfile, expectedHash != activeHash {
            return .failure(.message("Command rejected: the active schedule changed since it was read. Refresh and try again."))
        }
        return .success(backup.rawProfile)
    }

    /// Read-back verification is required: FileStorage.save itself does not throw on disk errors.
    static func replace(_ raw: String, file: String, storage: FileStorage, preservePrevious: Bool, expectedRaw: String? = nil) -> Bool {
        var succeeded = false
        storage.transaction { storage in
            guard let before = storage.retrieveRaw(file), expectedRaw == nil || before == expectedRaw else { return }
            if preservePrevious {
                let snapshot = RemoteTherapyBackup(rawProfile: before)
                let name = filename(file)
                storage.save(snapshot, as: name)
                guard let saved = storage.retrieve(name, as: RemoteTherapyBackup.self),
                      saved.isValid, saved.rawProfile == before else { return }
            }
            storage.save(raw, as: file)
            succeeded = storage.retrieveRaw(file) == raw
        }
        return succeeded
    }

    static func notification(label: String, restored: Bool, summary: String) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = "\(label) \(restored ? "atkurtas" : "pakeistas") iš LoopFollow"
        content.body = summary + (label == "ISF" ? " (mg/dL; Trio telefono laikas)" : " (g/U; Trio telefono laikas)")
        content.sound = nil
        content.interruptionLevel = .active
        content.userInfo = ["remote_therapy_change": true]
        return content
    }
}
