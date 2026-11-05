import Foundation
import Testing
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
}
