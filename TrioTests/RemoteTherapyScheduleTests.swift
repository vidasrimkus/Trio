import Foundation
import Testing
import UserNotifications
@testable import Trio

@Suite("Remote set_carb_ratios / set_isf commands") struct RemoteTherapyScheduleTests {
    private typealias R = RemoteTherapySchedule

    private func crSeg(_ start: String, _ ratio: String) -> R.CarbRatioSegment {
        R.CarbRatioSegment(start: start, ratio: Decimal(string: ratio)!)
    }

    private func isfSeg(_ start: String, _ mgdl: String) -> R.SensitivitySegment {
        R.SensitivitySegment(start: start, sensitivity: Decimal(string: mgdl)!)
    }

    private func validateCR(_ segments: [R.CarbRatioSegment], name: String = "Mokykla") -> Result<[CarbRatioEntry], R.Rejection> {
        R.validateCarbRatios(name: name, segments: segments)
    }

    private func validateISF(_ segments: [R.SensitivitySegment], name: String = "Mokykla")
        -> Result<[InsulinSensitivityEntry], R.Rejection>
    {
        R.validateSensitivities(name: name, segments: segments)
    }

    /// Stored-form entries from (minutes, value) pairs.
    private func cr(_ pairs: [(Int, String)]) -> [CarbRatioEntry] {
        pairs.map { CarbRatioEntry(start: R.storageStart($0.0), offset: $0.0, ratio: Decimal(string: $0.1)!) }
    }

    private func isf(_ pairs: [(Int, Int)]) -> [InsulinSensitivityEntry] {
        pairs.map { InsulinSensitivityEntry(sensitivity: Decimal($0.1), offset: $0.0, start: R.storageStart($0.0)) }
    }

    private func halfHour(_ index: Int) -> String {
        String(format: "%02d:%02d", index / 2, (index % 2) * 30)
    }

    // MARK: Decoding

    @Test("set_carb_ratios payload decodes") func decodesCarbRatios() throws {
        let json = #"""
        {"user":"LoopFollow","command_type":"set_carb_ratios","timestamp":1790400000,
         "carb_ratio_schedule":[{"start":"00:00","ratio":10},{"start":"06:30","ratio":8.5},{"start":"11:00","ratio":7.3}],
         "schedule_name":"Mokykla","expected_active_hash":"d0f731e0166dbc52"}
        """#
        let payload = try JSONDecoder().decode(CommandPayload.self, from: Data(json.utf8))
        #expect(payload.commandType == .setCarbRatios)
        #expect(payload.carbRatioSchedule == [crSeg("00:00", "10"), crSeg("06:30", "8.5"), crSeg("11:00", "7.3")])
        #expect(payload.scheduleName == "Mokykla")
        #expect(payload.expectedActiveHash == "d0f731e0166dbc52")
        #expect(payload.isfSchedule == nil)
        #expect(payload.basalSchedule == nil)
        #expect(payload.basalScheduleName == nil)
        #expect(TrioRemoteControl.CommandType.setCarbRatios.rawValue == "set_carb_ratios")
        #expect(payload.humanReadableDescription().contains("Carb Ratios: Mokykla, 3 entries."))
        // What was decoded passes validation exactly as sent (7.3 must not arrive as 7.2999…).
        let entries = try R.validateCarbRatios(name: payload.scheduleName!, segments: payload.carbRatioSchedule!).get()
        #expect(entries.map(\.ratio) == [10, Decimal(string: "8.5")!, Decimal(string: "7.3")!])
    }

    @Test("set_isf payload decodes") func decodesISF() throws {
        let json = #"""
        {"user":"LoopFollow","command_type":"set_isf","timestamp":1790400000,
         "isf_schedule":[{"start":"00:00","sensitivity":180},{"start":"08:00","sensitivity":150}],
         "schedule_name":"Vasara","expected_active_hash":"88ce4c3c77da0c2b"}
        """#
        let payload = try JSONDecoder().decode(CommandPayload.self, from: Data(json.utf8))
        #expect(payload.commandType == .setISF)
        #expect(payload.isfSchedule == [isfSeg("00:00", "180"), isfSeg("08:00", "150")])
        #expect(payload.scheduleName == "Vasara")
        #expect(payload.expectedActiveHash == "88ce4c3c77da0c2b")
        #expect(payload.carbRatioSchedule == nil)
        #expect(TrioRemoteControl.CommandType.setISF.rawValue == "set_isf")
        #expect(payload.humanReadableDescription().contains("ISF: Vasara, 2 entries."))
    }

    @Test("A command without its schedule decodes with nil fields") func incompletePayload() throws {
        let json = #"{"user":"LoopFollow","command_type":"set_isf","timestamp":1790400000,"schedule_name":"X"}"#
        let payload = try JSONDecoder().decode(CommandPayload.self, from: Data(json.utf8))
        #expect(payload.isfSchedule == nil)
        #expect(payload.expectedActiveHash == nil)
    }

    // MARK: Validation — shape

    @Test("Valid schedules become the editors' storage entries") func storageFormat() throws {
        let crEntries = try validateCR([crSeg("00:00", "10"), crSeg("06:30", "8.5"), crSeg("23:30", "12.0")]).get()
        #expect(crEntries.map { "\($0.start)|\($0.offset)|\($0.ratio)" } == ["00:00:00|0|10", "06:30:00|390|8.5", "23:30:00|1410|12"])
        let isfEntries = try validateISF([isfSeg("00:00", "180"), isfSeg("12:30", "47")]).get()
        #expect(isfEntries.map { "\($0.start)|\($0.offset)|\($0.sensitivity)" } == ["00:00:00|0|180", "12:30:00|750|47"])
    }

    @Test(
        "Starts must be HH:00 or HH:30",
        arguments: ["00:15", "02:01", "2:00", "24:00", "02", "aa:00", "02:00:00", "+1:00", "02:3", ""]
    ) func badStart(start: String) {
        #expect(throws: R.Rejection.self) { try validateCR([crSeg("00:00", "10"), crSeg(start, "9")]).get() }
        #expect(throws: R.Rejection.self) { try validateISF([isfSeg("00:00", "100"), isfSeg(start, "90")]).get() }
    }

    @Test("First entry at 00:00, strictly increasing, 1–48 entries") func shape() {
        // First not at 00:00.
        #expect(throws: R.Rejection.self) { try validateCR([crSeg("00:30", "10")]).get() }
        #expect(throws: R.Rejection.self) { try validateISF([isfSeg("06:00", "100")]).get() }
        // A 00:15 start is refused even as the first entry.
        #expect(throws: R.Rejection.self) { try validateCR([crSeg("00:15", "10")]).get() }
        // Not increasing / duplicate.
        #expect(throws: R.Rejection.self) { try validateCR([crSeg("00:00", "10"), crSeg("05:00", "9"), crSeg("03:00", "8")]).get() }
        #expect(throws: R.Rejection.self) { try validateISF([isfSeg("00:00", "100"), isfSeg("00:00", "90")]).get() }
        // Empty.
        #expect(throws: R.Rejection.self) { try validateCR([]).get() }
        #expect(throws: R.Rejection.self) { try validateISF([]).get() }
        // 48 entries (every half hour) pass; 49 are refused.
        let all48 = (0 ..< 48).map { crSeg(halfHour($0), "10") }
        let all48Count = (try? validateCR(all48).get())?.count
        #expect(all48Count == 48)
        let isf48 = (0 ..< 48).map { isfSeg(halfHour($0), "100") }
        let isf48Count = (try? validateISF(isf48).get())?.count
        #expect(isf48Count == 48)
        let cr49 = all48 + [crSeg("23:30", "10")]
        #expect(throws: R.Rejection.self) { try validateCR(cr49).get() }
        let isf49 = isf48 + [isfSeg("23:30", "100")]
        #expect(throws: R.Rejection.self) { try validateISF(isf49).get() }
    }

    // MARK: Validation — values

    @Test("Carb ratio 1.0–50.0 in whole tenths") func carbRatioValues() {
        for bad in ["0.9", "50.1", "8.55", "0", "-5", "10.05"] {
            #expect(throws: R.Rejection.self) { try validateCR([crSeg("00:00", bad)]).get() }
        }
        for good in ["1", "1.0", "50", "50.0", "8.5", "7.3", "12"] {
            #expect((try? validateCR([crSeg("00:00", good)]).get()) != nil)
        }
    }

    @Test("ISF integer 9–540 mg/dL") func sensitivityValues() {
        for bad in ["8", "541", "0", "-50", "180.5", "46.1"] {
            #expect(throws: R.Rejection.self) { try validateISF([isfSeg("00:00", bad)]).get() }
        }
        for good in ["9", "540", "46", "47", "180", "180.0"] {
            #expect((try? validateISF([isfSeg("00:00", good)]).get()) != nil)
        }
    }

    @Test("Name rules (same as basal_schedule_name)") func names() {
        for bad in ["", "  ", String(repeating: "a", count: 31), "a\"b", "a\nb", "a\tb"] {
            #expect(throws: R.Rejection.self) { try validateCR([crSeg("00:00", "10")], name: bad).get() }
            #expect(throws: R.Rejection.self) { try validateISF([isfSeg("00:00", "100")], name: bad).get() }
        }
        for good in ["Savaitgalis – žiema", String(repeating: "ž", count: 30), "A"] {
            #expect((try? validateCR([crSeg("00:00", "10")], name: good).get()) != nil)
            #expect((try? validateISF([isfSeg("00:00", "100")], name: good).get()) != nil)
        }
    }

    // MARK: Hash vectors (shared with LoopFollow, CUSTOMIZATIONS.md §11)

    @Test("CR hash vectors") func carbRatioVectors() {
        let cr1 = cr([(0, "10.0"), (360, "8.5"), (660, "12.0"), (1020, "10.5")])
        #expect(R.carbRatioHash(cr1) == "d0f731e0166dbc52")
        #expect(R.carbRatioHash(Array(cr1.reversed())) == "d0f731e0166dbc52")
        #expect(R.carbRatioHash(cr([(0, "10")])) == "eb0120f2d30d1482")
        #expect(R.carbRatioHash(cr([(0, "10.00")])) == "eb0120f2d30d1482")
        #expect(R.carbRatioHash(cr([(0, "9.0"), (450, "7.5"), (1200, "11.0")])) == "82bc62b67556f34a")
        #expect(R.carbRatioHash(cr([(0, "9.0"), (180, "9.0"), (450, "7.5"), (1200, "11.0")])) == "82bc62b67556f34a")
        // CR4 wraps (no 00:00 entry); the hash is defined, validation refuses the schedule.
        #expect(R.carbRatioHash(cr([(360, "8.0"), (1260, "12.0")])) == "ae96c8ecc9e86a8b")
        #expect(throws: R.Rejection.self) { try validateCR([crSeg("06:00", "8.0"), crSeg("21:00", "12.0")]).get() }
    }

    @Test("ISF Nightscout-form hash vectors, mg/dL and mmol/L") func sensitivityVectors() {
        let isf1 = isf([(0, 180), (480, 150), (1320, 200)])
        #expect(R.sensitivityNightscoutHash(isf1, units: .mgdL) == "88ce4c3c77da0c2b")
        #expect(R.sensitivityNightscoutHash(isf1, units: .mmolL) == "2d0d147868c7adf5")
        let isf2 = isf([(0, 46), (750, 47)])
        #expect(R.sensitivityNightscoutHash(isf2, units: .mgdL) == "4701d2c3453569ad")
        #expect(R.sensitivityNightscoutHash(isf2, units: .mmolL) == "39a70ffcfeb762f2")
    }

    @Test("Validated entries hash like the stored form") func validatedHashes() throws {
        let entries = try validateCR([crSeg("00:00", "10.0"), crSeg("06:00", "8.5"), crSeg("11:00", "12.0"), crSeg("17:00", "10.5")])
            .get()
        #expect(R.carbRatioHash(entries) == "d0f731e0166dbc52")
        let isfEntries = try validateISF([isfSeg("00:00", "180"), isfSeg("08:00", "150"), isfSeg("22:00", "200")]).get()
        #expect(R.sensitivityNightscoutHash(isfEntries, units: .mgdL) == "88ce4c3c77da0c2b")
        #expect(R.sensitivityNightscoutHash(isfEntries, units: .mmolL) == "2d0d147868c7adf5")
    }

    // MARK: Already active (exact comparison of the 48 slots)

    @Test("Already active: same delivered schedule, however it is split") func alreadyActive() throws {
        let stored = cr([(0, "9.0"), (180, "9.0"), (450, "7.5"), (1200, "11.0")])
        let sent = try validateCR([crSeg("00:00", "9"), crSeg("07:30", "7.5"), crSeg("20:00", "11")]).get()
        #expect(R.carbRatioSlots(sent) == R.carbRatioSlots(stored))
        let changed = try validateCR([crSeg("00:00", "9"), crSeg("07:30", "7.6"), crSeg("20:00", "11")]).get()
        #expect(R.carbRatioSlots(changed) != R.carbRatioSlots(stored))
        // Empty stored schedule is never "already active".
        #expect(R.carbRatioSlots(sent) != R.carbRatioSlots([]))
        #expect(R.carbRatioSlots([]).isEmpty)
    }

    @Test("ISF already-active is exact mg/dL even where the mmol/L form cannot tell") func isfExactVersusNightscoutForm() throws {
        let stored = isf([(0, 46)])
        let sent = try validateISF([isfSeg("00:00", "46"), isfSeg("12:30", "47")]).get()
        // mmol/L Nightscout form: 46 and 47 are both 2.6 → same hash, so the guard passes …
        #expect(R.sensitivityNightscoutHash(sent, units: .mmolL) == R.sensitivityNightscoutHash(stored, units: .mmolL))
        #expect(R.sensitivityNightscoutHash(stored, units: .mmolL) == "39a70ffcfeb762f2")
        // … but the exact slots differ, so it is NOT "already active" and the new values are written.
        #expect(R.sensitivitySlots(sent) != R.sensitivitySlots(stored))
        // In mg/dL the two forms differ.
        #expect(R.sensitivityNightscoutHash(sent, units: .mgdL) != R.sensitivityNightscoutHash(stored, units: .mgdL))
        // Same values split differently → already active.
        let split = isf([(0, 46), (300, 46), (750, 47)])
        #expect(R.sensitivitySlots(sent) == R.sensitivitySlots(split))
    }

    // MARK: Pre-check

    @Test("Only refused while a loop runs") func precheck() {
        #expect(R.precheck(looping: false) == nil)
        #expect(R.precheck(looping: true) != nil)
    }

    // MARK: Rejection texts (what logError sends to LoopFollow)

    /// "match" → the hash of `stored`, i.e. the guard passes.
    private func crPlan(
        _ schedule: [R.CarbRatioSegment]? = nil,
        name: String? = "Mokykla",
        expected: String? = "match",
        looping: Bool = false,
        stored: [CarbRatioEntry]? = nil
    ) -> Result<R.Plan<CarbRatioEntry>, R.Rejection> {
        let storedEntries = stored ?? cr([(0, "12")])
        return R.planCarbRatios(
            schedule: schedule,
            name: name,
            expectedHash: expected == "match" ? R.carbRatioHash(storedEntries) : expected,
            looping: looping,
            stored: { storedEntries }
        )
    }

    private func isfPlan(
        _ schedule: [R.SensitivitySegment]? = nil,
        name: String? = "Mokykla",
        expected: String? = "match",
        looping: Bool = false,
        units: GlucoseUnits = .mmolL,
        stored: [InsulinSensitivityEntry]? = nil
    ) -> Result<R.Plan<InsulinSensitivityEntry>, R.Rejection> {
        let storedEntries = stored ?? isf([(0, 100)])
        return R.planSensitivities(
            schedule: schedule,
            name: name,
            expectedHash: expected == "match" ? R.sensitivityNightscoutHash(storedEntries, units: units) : expected,
            looping: looping,
            units: units,
            stored: { storedEntries }
        )
    }

    private func text<T>(_ result: Result<T, R.Rejection>) -> String? {
        if case let .failure(rejection) = result { return rejection.text }
        return nil
    }

    private var okCR: [R.CarbRatioSegment] { [crSeg("00:00", "10")] }
    private var okISF: [R.SensitivitySegment] { [isfSeg("00:00", "90")] }

    @Test("Rejected: incomplete payload") func rejectIncomplete() {
        let crText = "Command rejected: carb ratio schedule data is incomplete."
        #expect(text(crPlan(nil)) == crText)
        #expect(text(crPlan(okCR, name: nil)) == crText)
        #expect(text(crPlan(okCR, expected: nil)) == crText)
        let isfText = "Command rejected: ISF schedule data is incomplete."
        #expect(text(isfPlan(nil)) == isfText)
        #expect(text(isfPlan(okISF, name: nil)) == isfText)
        #expect(text(isfPlan(okISF, expected: nil)) == isfText)
    }

    @Test("Rejected: loop running (checked before validation)") func rejectLooping() {
        let loopText = "Command rejected: A loop cycle is running. Try again in a minute."
        #expect(text(crPlan(okCR, looping: true)) == loopText)
        #expect(text(isfPlan(okISF, looping: true)) == loopText)
        #expect(text(crPlan([crSeg("06:00", "99")], looping: true)) == loopText)
    }

    @Test("Rejected: empty and more than 48 entries") func rejectCount() {
        let countText = "Command rejected: A schedule needs 1–48 entries."
        #expect(text(crPlan([])) == countText)
        #expect(text(isfPlan([])) == countText)
        let cr49 = (0 ..< 48).map { crSeg(halfHour($0), "10") } + [crSeg("23:30", "10")]
        let isf49 = (0 ..< 48).map { isfSeg(halfHour($0), "90") } + [isfSeg("23:30", "90")]
        #expect(text(crPlan(cr49)) == countText)
        #expect(text(isfPlan(isf49)) == countText)
    }

    @Test("Rejected: first entry not at 00:00") func rejectFirst() {
        let firstText = "Command rejected: The first entry must start at 00:00."
        #expect(text(crPlan([crSeg("00:30", "10")])) == firstText)
        #expect(text(isfPlan([isfSeg("06:00", "90")])) == firstText)
    }

    @Test("Rejected: off the 30-minute grid", arguments: ["00:15", "24:00", "7:30"]) func rejectOffGrid(start: String) {
        let gridText = "Command rejected: \(start): entries must start on the hour or half hour (HH:00 or HH:30)."
        #expect(text(crPlan([crSeg("00:00", "10"), crSeg(start, "9")])) == gridText)
        #expect(text(isfPlan([isfSeg("00:00", "90"), isfSeg(start, "80")])) == gridText)
        // A first entry off the grid gets the grid text too.
        #expect(text(crPlan([crSeg(start, "9")])) == gridText)
    }

    @Test("Rejected: not strictly increasing (equal, decreasing)") func rejectOrder() {
        let equal = text(crPlan([crSeg("00:00", "10"), crSeg("05:00", "9"), crSeg("05:00", "8")]))
        #expect(equal == "Command rejected: 05:00: entry times must be strictly increasing.")
        let decreasing = text(isfPlan([isfSeg("00:00", "90"), isfSeg("05:00", "80"), isfSeg("03:00", "70")]))
        #expect(decreasing == "Command rejected: 03:00: entry times must be strictly increasing.")
    }

    @Test("Rejected: CR below 1.0, above 50.0, not whole tenths") func rejectCarbRatioValue() {
        #expect(text(crPlan([crSeg("00:00", "0.9")])) == "Command rejected: 00:00: carb ratio 0.9 g/U is outside 1–50 g/U.")
        #expect(text(crPlan([crSeg("00:00", "50.1")])) == "Command rejected: 00:00: carb ratio 50.1 g/U is outside 1–50 g/U.")
        let tenths = text(crPlan([crSeg("00:00", "8.55")]))
        #expect(tenths == "Command rejected: 00:00: carb ratio 8.55 g/U must be a whole number of tenths.")
    }

    @Test("Rejected: ISF below 9, above 540, not a whole number") func rejectSensitivityValue() {
        #expect(text(isfPlan([isfSeg("00:00", "8")])) == "Command rejected: 00:00: ISF 8 mg/dL is outside 9–540 mg/dL.")
        #expect(text(isfPlan([isfSeg("00:00", "541")])) == "Command rejected: 00:00: ISF 541 mg/dL is outside 9–540 mg/dL.")
        let fraction = text(isfPlan([isfSeg("00:00", "180.5")]))
        #expect(fraction == "Command rejected: 00:00: ISF 180.5 must be a whole number of mg/dL.")
    }

    @Test("Rejected: name empty, too long, quote, control character") func rejectName() {
        let lengthText = "Command rejected: Schedule name must be 1–30 characters."
        let charText = "Command rejected: Schedule name must not contain quotes or control characters."
        let cases: [(String, String)] = [
            ("", lengthText), (" ", lengthText), (String(repeating: "a", count: 31), lengthText),
            ("a\"b", charText), ("a\u{0007}b", charText), ("a\nb", charText)
        ]
        for (name, expected) in cases {
            #expect(text(crPlan(okCR, name: name)) == expected)
            #expect(text(isfPlan(okISF, name: name)) == expected)
        }
    }

    @Test("Rejected: expected hash differs from the stored schedule") func rejectHashMismatch() {
        let storedCR = cr([(0, "10.5")])
        let crActive = R.carbRatioHash(storedCR)
        let crText = text(crPlan(okCR, expected: "0000000000000000", stored: storedCR))
        #expect(
            crText ==
                "Command rejected: the active carb ratios changed since they were read (expected 0000000000000000, active \(crActive)). Refresh and try again."
        )
        // A mg/dL-form hash sent while Trio shows mmol/L does not match the mmol/L form.
        let storedISF = isf([(0, 180), (480, 150), (1320, 200)])
        let isfText = text(isfPlan(okISF, expected: "88ce4c3c77da0c2b", units: .mmolL, stored: storedISF))
        #expect(
            isfText ==
                "Command rejected: the active ISF changed since it was read (expected 88ce4c3c77da0c2b, active 2d0d147868c7adf5). Refresh and try again."
        )
    }

    @Test("Stored schedule is not read when the payload is refused") func storedNotReadOnRejection() {
        var reads = 0
        _ = R.planCarbRatios(schedule: [], name: "X", expectedHash: "x", looping: false, stored: { reads += 1; return [] })
        _ = R.planSensitivities(
            schedule: nil, name: "X", expectedHash: "x", looping: false, units: .mgdL, stored: { reads += 1; return [] }
        )
        #expect(reads == 0)
    }

    @Test("Accepted: write plan, and already-active plan") func plans() {
        let written = crPlan(
            [crSeg("00:00", "10.0"), crSeg("06:00", "8.5"), crSeg("11:00", "12.0"), crSeg("17:00", "10.5")],
            stored: cr([(0, "10")])
        )
        guard case let .success(.write(name, entries, activeHash, newHash)) = written else {
            Issue.record("expected a write plan")
            return
        }
        #expect(name == "Mokykla")
        #expect(entries.count == 4)
        #expect(activeHash == "eb0120f2d30d1482")
        #expect(newHash == "d0f731e0166dbc52")
        // Already active wins even with a stale expected hash (re-sending is harmless).
        guard case let .success(.alreadyActive(_, hash)) = crPlan(okCR, expected: "stale", stored: cr([(0, "10")])) else {
            Issue.record("expected already active")
            return
        }
        #expect(hash == "eb0120f2d30d1482")
    }

    // MARK: Time zone

    /// Starts are minutes from midnight in the phone's local time and are stored as received; nothing in
    /// RemoteTherapySchedule uses a Date, Calendar or TimeZone. NSTimeZone.default is deliberately NOT mutated: it is
    /// process-global and suites run in parallel (ParityHarness.swift pins the zone from outside for that reason).
    /// Instead a local 07:30 is built in each zone and must give the same stored entry, slots and hash.
    @Test("Local-time starts are stored the same in every time zone", arguments: ["UTC", "Europe/Vilnius", "America/New_York"])
    func timeZoneIndependent(zone: String) throws {
        let tz = try #require(TimeZone(identifier: zone))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = tz
        // 2026-03-29 is the DST change day in Vilnius.
        let date = try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 29, hour: 7, minute: 30)))
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let localStart = String(format: "%02d:%02d", parts.hour ?? -1, parts.minute ?? -1)
        #expect(localStart == "07:30")

        let crEntries = try validateCR([crSeg("00:00", "9.0"), crSeg(localStart, "7.5"), crSeg("20:00", "11.0")]).get()
        #expect(crEntries.map { "\($0.start)|\($0.offset)" } == ["00:00:00|0", "07:30:00|450", "20:00:00|1200"])
        #expect(R.carbRatioSlots(crEntries)[15] == Decimal(string: "7.5")!)
        #expect(R.carbRatioHash(crEntries) == "82bc62b67556f34a")
        let isfEntries = try validateISF([isfSeg("00:00", "180"), isfSeg("08:00", "150"), isfSeg("22:00", "200")]).get()
        #expect(isfEntries.map { "\($0.start)|\($0.offset)" } == ["00:00:00|0", "08:00:00|480", "22:00:00|1320"])
        #expect(R.sensitivityNightscoutHash(isfEntries, units: .mgdL) == "88ce4c3c77da0c2b")
        // The editors' own conversion (fixed GMT formatter) gives the same start string.
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "HH:mm:ss"
        #expect(formatter.string(from: Date(timeIntervalSince1970: 450 * 60)) == R.storageStart(450))
    }

    // MARK: Units

    @Test("90 mg/dL is stored as 90 mg/dL in both app-unit modes", arguments: [false, true])
    func storedAlwaysMgdl(mmol: Bool) throws {
        let units: GlucoseUnits = mmol ? .mmolL : .mgdL
        guard case let .success(.write(_, entries, _, _)) = isfPlan(okISF, units: units) else {
            Issue.record("expected a write plan")
            return
        }
        let profile = R.sensitivityProfile(entries)
        #expect(profile.units == .mgdL)
        #expect(profile.userPreferredUnits == .mgdL)
        let stored = try #require(profile.sensitivities.first?.sensitivity)
        #expect(stored == 90)
        for wrong in ["1620", "0.28", "5.0"] {
            #expect(stored != Decimal(string: wrong)!)
        }
    }

    @Test("Nightscout form of 90 mg/dL: 5.0 in mmol/L (4.995 → 5.0), 90 in mg/dL") func nightscoutForm() {
        // GlucoseUnits.exchangeRate is a Decimal built from a float literal (0.05550000000000001024, seen in CI), not
        // exactly 0.0555. The excess is positive and tiny, so half-up results equal exact 0.0555 arithmetic (what
        // LoopFollow uses: tenths = (mg × 555 + 500) / 1000) for every mg/dL value the ISF accepts.
        for mgdl in 9 ... 540 {
            let exactTenths = Decimal((mgdl * 555 + 500) / 1000)
            let trio = R.nightscoutSensitivity(Decimal(mgdl), units: .mmolL)
            #expect(trio * 10 == exactTenths, "\(mgdl) mg/dL")
        }
        #expect(R.nightscoutSensitivity(100, units: .mmolL) == Decimal(string: "5.6")!)
        #expect(R.nightscoutSensitivity(90, units: .mmolL) == Decimal(string: "5.0")!)
        #expect(R.nightscoutSensitivity(90, units: .mgdL) == 90)
        let entries = isf([(0, 90)])
        #expect(R.sensitivityNightscoutHash(entries, units: .mmolL) != R.sensitivityNightscoutHash(entries, units: .mgdL))
    }

    // MARK: mmol/L editor guard

    @Test("mmol/L: 47 is refused (use 46), 46 accepted; mg/dL: 47 accepted") func mmolEditorGuard() {
        #expect(
            text(isfPlan([isfSeg("00:00", "47")], units: .mmolL))
                == "Command rejected: 00:00: ISF 47 mg/dL is not a value Trio's mmol/L ISF editor can show (use 46)."
        )
        let later = text(isfPlan([isfSeg("00:00", "46"), isfSeg("12:30", "47")], units: .mmolL))
        #expect(later == "Command rejected: 12:30: ISF 47 mg/dL is not a value Trio's mmol/L ISF editor can show (use 46).")
        #expect(text(isfPlan([isfSeg("00:00", "46")], units: .mmolL, stored: isf([(0, 50)]))) == nil)
        #expect(text(isfPlan([isfSeg("00:00", "47")], units: .mgdL, stored: isf([(0, 50)]))) == nil)
        #expect(R.mmolEditorRejection(isf([(0, 47)]), units: .mgdL) == nil)
    }

    @Test("Every value the mmol/L ISF editor produces passes the guard") func editorValuesPass() {
        let setting = PickerSetting(value: 100, step: 1, min: 9, max: 540, type: .glucose)
        let values = PickerSettingsProvider.shared.generatePickerValues(from: setting, units: .mmolL)
        #expect(values.count == 296)
        for value in values {
            #expect(R.smallestMgdlInMmolGroup(value) == value, "\(value) mg/dL")
            #expect(R.mmolEditorRejection(isf([(0, NSDecimalNumber(decimal: value).intValue)]), units: .mmolL) == nil)
        }
        // And nothing else passes: the accepted set is exactly the editor's set.
        let accepted = (9 ... 540).filter { R.mmolEditorRejection(isf([(0, $0)]), units: .mmolL) == nil }.map { Decimal($0) }
        #expect(accepted == values)
    }

    @Test(
        "Contract mmol/L → mg/dL vectors are the smallest of their group",
        arguments: [("0.6", 10), ("2.2", 39), ("2.6", 46), ("8.3", 149), ("10.0", 180), ("0.5", 9), ("5.0", 90), ("30.0", 540)]
    ) func mmolVectors(mmol: String, mgdl: Int) {
        let value = Decimal(mgdl)
        #expect(R.nightscoutSensitivity(value, units: .mmolL) == Decimal(string: mmol)!)
        #expect(R.smallestMgdlInMmolGroup(value) == value)
        if mgdl > 9 { #expect(R.nightscoutSensitivity(value - 1, units: .mmolL) != Decimal(string: mmol)!) }
        #expect(R.mmolEditorRejection(isf([(0, mgdl)]), units: .mmolL) == nil)
    }

    // MARK: Units given to the plan

    @Test("The plan hashes in the units it is given; the saved profile is mg/dL") func planUnits() {
        let stored = isf([(0, 180), (480, 150), (1320, 200)])
        let sent = [isfSeg("00:00", "180"), isfSeg("08:00", "149"), isfSeg("22:00", "200")]
        // mmol/L plan: the guard compares against the mmol/L Nightscout form of the stored schedule.
        guard case let .success(.write(_, entries, mmolActive, mmolNew)) = isfPlan(
            sent, expected: "2d0d147868c7adf5", units: .mmolL, stored: stored
        ) else {
            Issue.record("expected a write plan in mmol/L")
            return
        }
        #expect(mmolActive == "2d0d147868c7adf5")
        #expect(mmolNew == R.sensitivityNightscoutHash(isf([(0, 180), (480, 149), (1320, 200)]), units: .mmolL))
        let profile = R.sensitivityProfile(entries)
        #expect(profile.units == .mgdL)
        #expect(profile.userPreferredUnits == .mgdL)
        #expect(profile.sensitivities.map(\.sensitivity) == [180, 149, 200])
        // mg/dL plan: same stored schedule, mg/dL form.
        guard case let .success(.write(_, _, mgdlActive, _)) = isfPlan(
            sent, expected: "88ce4c3c77da0c2b", units: .mgdL, stored: stored
        ) else {
            Issue.record("expected a write plan in mg/dL")
            return
        }
        #expect(mgdlActive == "88ce4c3c77da0c2b")
        // The mmol/L hash is refused by a mg/dL plan.
        #expect(text(isfPlan(sent, expected: "2d0d147868c7adf5", units: .mgdL, stored: stored)) != nil)
    }

    @Test("Exact ±20% accepted; ±20.1% refused before display rounding", arguments: ["CR", "ISF"])
    func exactChangeBoundary(label: String) {
        let old = Array(repeating: Decimal(100), count: 48)
        for value in ["80", "120"] {
            #expect(R.changeRejection(old: old, new: Array(repeating: Decimal(string: value)!, count: 48), label: label, unit: "test") == nil)
        }
        for value in ["79.9", "120.1"] {
            let rejection = R.changeRejection(old: old, new: Array(repeating: Decimal(string: value)!, count: 48), label: label, unit: "test")
            #expect(rejection?.text.contains("20.1") == true)
        }
    }

    @Test("CR plan enforces ±20% in exact g/U") func crPlanChangeLimit() {
        for value in ["8", "12"] {
            #expect(text(crPlan([crSeg("00:00", value)], stored: cr([(0, "10")]))) == nil)
        }
        for value in ["7.9", "12.1"] {
            #expect(text(crPlan([crSeg("00:00", value)], stored: cr([(0, "10")])))?.contains("±20") == true)
        }
    }

    @Test("ISF plan enforces exact mg/dL ±20% in both display units", arguments: [false, true])
    func isfPlanChangeLimit(mmol: Bool) {
        let units: GlucoseUnits = mmol ? .mmolL : .mgdL
        for value in ["72", "108"] {
            #expect(text(isfPlan([isfSeg("00:00", value)], units: units, stored: isf([(0, 90)]))) == nil)
        }
        for value in ["70", "110"] {
            #expect(text(isfPlan([isfSeg("00:00", value)], units: units, stored: isf([(0, 90)])))?.contains("±20") == true)
        }
    }

    @Test("Changed segment boundaries compare every half hour, not segment indexes") func movedBoundary() {
        let rejection = text(crPlan(
            [crSeg("00:00", "10"), crSeg("07:30", "20")], stored: cr([(0, "10"), (480, "20")])
        ))
        #expect(rejection?.contains("07:30: 10 → 20") == true)
        #expect(rejection?.contains("100%") == true)
        #expect(R.changeRejection(old: [], new: Array(repeating: 10, count: 48), label: "CR", unit: "g/U") != nil)
        #expect(R.changeRejection(old: Array(repeating: 0, count: 48), new: Array(repeating: 10, count: 48), label: "CR", unit: "g/U") != nil)
    }

}


@Suite("Exact remote therapy backup") struct RemoteTherapyBackupTests {
    @Test("Set then restore preserves CR and mg/dL ISF raw bytes, even redundant segments", arguments: [false, true])
    func exactRoundTrip(isf: Bool) throws {
        let storage = BaseFileStorage()
        let file = "remote-therapy-test-" + UUID().uuidString + ".json"
        defer { storage.remove(file); storage.remove(RemoteTherapyBackup.filename(file)) }
        // ISF 47 is deliberately not a mmol/L picker value. Restore must not snap it to 46.
        let old = isf
            ? """
            { "units":"mg/dL", "user_preferred_units":"mg/dL", "sensitivities":[
              {"start":"00:00:00","offset":0,"sensitivity":47},
              {"start":"08:00:00","offset":480,"sensitivity":47}] }
            """
            : """
            { "units":"grams", "schedule":[{"start":"00:00:00","offset":0,"ratio":7.0},
              {"start":"10:00:00","offset":600,"ratio":7.0}] }
            """
        storage.save(old, as: file)
        let changed = isf
            ? RemoteTherapySchedule.sensitivityProfile([InsulinSensitivityEntry(sensitivity: 38, offset: 0, start: "00:00:00")]).rawJSON
            : CarbRatios(units: .grams, schedule: [CarbRatioEntry(start: "00:00:00", offset: 0, ratio: 5.6)]).rawJSON
        let replaced = RemoteTherapyBackup.replace(changed, file: file, storage: storage, preservePrevious: true)
        #expect(replaced)
        let backup = try #require(storage.retrieve(RemoteTherapyBackup.filename(file), as: RemoteTherapyBackup.self))
        #expect(backup.isValid && backup.rawProfile == old)
        #expect(backup.exactHash == RemoteTherapyBackup.hash(old))
        #expect(abs(backup.savedAt.timeIntervalSinceNow) < 30)
        // Returning from a 20% decrease can exceed +20%; exact undo still succeeds.
        let currentValue: Decimal = isf ? 38 : 5.6
        let previousValue: Decimal = isf ? 47 : 7
        #expect(RemoteTherapySchedule.changeRejection(
            old: Array(repeating: currentValue, count: 48), new: Array(repeating: previousValue, count: 48), label: "test", unit: "test"
        ) != nil)
        let raw = try RemoteTherapyBackup.restoreRaw(file: file, storage: storage, expectedHash: "current", activeHash: "current", looping: false).get()
        let restored = RemoteTherapyBackup.replace(raw, file: file, storage: storage, preservePrevious: false)
        #expect(restored)
        #expect(storage.retrieveRaw(file)?.data(using: .utf8) == old.data(using: .utf8))
        let retry = try RemoteTherapyBackup.restoreRaw(file: file, storage: storage, expectedHash: "stale", activeHash: "restored", looping: false).get()
        #expect(retry == old) // no toggle and original backup remains
        #expect(storage.retrieve(RemoteTherapyBackup.filename(file), as: RemoteTherapyBackup.self)?.rawProfile == old)
    }

    @Test("Restore refuses missing/corrupt backup, missing/stale hash and a running loop") func restoreGuards() {
        let storage = BaseFileStorage()
        let file = "remote-therapy-guards-" + UUID().uuidString
        defer { storage.remove(file); storage.remove(RemoteTherapyBackup.filename(file)) }
        func refused(_ expected: String?, _ looping: Bool = false) -> Bool {
            if case .failure = RemoteTherapyBackup.restoreRaw(file: file, storage: storage, expectedHash: expected, activeHash: "current", looping: looping) { return true }
            return false
        }
        #expect(refused("current"))
        storage.save("changed", as: file)
        storage.save(RemoteTherapyBackup(rawProfile: "previous"), as: RemoteTherapyBackup.filename(file))
        #expect(refused(nil))
        #expect(refused("stale"))
        #expect(refused("current", true))
        let corrupt = RemoteTherapyBackup(rawProfile: "previous").rawJSON.replacingOccurrences(of: "previous", with: "tampered")
        storage.save(corrupt, as: RemoteTherapyBackup.filename(file))
        #expect(refused("current"))
        #expect(storage.retrieveRaw(file) == "changed")
    }

    @Test("Concurrent active-file changes are refused inside the storage transaction") func changedSource() {
        let storage = BaseFileStorage()
        let file = "remote-therapy-race-" + UUID().uuidString
        defer { storage.remove(file); storage.remove(RemoteTherapyBackup.filename(file)) }
        storage.save("manual change", as: file)
        let saved = RemoteTherapyBackup.replace("new", file: file, storage: storage, preservePrevious: true, expectedRaw: "earlier read")
        #expect(!saved)
        #expect(storage.retrieveRaw(file) == "manual change")
        #expect(storage.retrieve(RemoteTherapyBackup.filename(file), as: RemoteTherapyBackup.self) == nil)
    }

    @Test("Missing active file cannot be overwritten without a verified backup") func missingSource() {
        let storage = BaseFileStorage()
        let file = "remote-therapy-missing-" + UUID().uuidString
        let saved = RemoteTherapyBackup.replace("new", file: file, storage: storage, preservePrevious: true)
        #expect(!saved)
        #expect(storage.retrieveRaw(file) == nil)
    }

    @Test("Applied/restore child notification names changes and is silent and noncritical") func notificationContent() {
        let summary = RemoteTherapySchedule.changeSummary(old: Array(repeating: 7, count: 48), new: Array(repeating: 7, count: 20) + Array(repeating: 8, count: 28))
        let content = RemoteTherapyBackup.notification(label: "CR", restored: false, summary: summary)
        #expect(content.title == "CR pakeistas iš LoopFollow")
        #expect(content.body.contains("10:00 7 → 8"))
        #expect(content.sound == nil)
        #expect(content.interruptionLevel == .active)
        #expect(RemoteTherapyBackup.notification(label: "ISF", restored: true, summary: "test").title == "ISF atkurtas iš LoopFollow")
    }

    @Test("Restore commands decode with correlation ID; response includes the same machine ID") func commandAndResponse() throws {
        let id = UUID()
        for command in ["restore_previous_carb_ratios", "restore_previous_isf"] {
            let json = """
            {"user":"LoopFollow","command_type":"\(command)","command_id":"\(id.uuidString)","timestamp":100,"expected_active_hash":"abc"}
            """
            let payload = try JSONDecoder().decode(CommandPayload.self, from: Data(json.utf8))
            #expect(payload.commandID == id)
            #expect(payload.expectedActiveHash == "abc")
            #expect(payload.carbRatioSchedule == nil && payload.isfSchedule == nil)
        }
        let response = RemoteNotificationResponseManager.NotificationPayload(
            aps: .init(alert: .init(title: "Command Successful", body: "done")),
            commandStatus: "success", commandType: "set_isf", commandID: id, activeHash: "abc", timestamp: 100
        )
        let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(response)) as? [String: Any])
        #expect(json["command_id"] as? String == id.uuidString)
        #expect(json["active_hash"] as? String == "abc")
        #expect((json["aps"] as? [String: Any])?["content-available"] as? Int == 1)
    }
}
