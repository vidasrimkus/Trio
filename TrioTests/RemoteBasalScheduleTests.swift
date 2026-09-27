import Foundation
import Testing
@testable import Trio

@Suite("Remote set_basal_schedule command") struct RemoteBasalScheduleTests {
    private typealias R = RemoteBasalSchedule

    /// Dana-like table: 0.01 U/h steps up to 5 U/h (the test does not depend on the real driver).
    private let rates001 = (1 ... 500).map { Double($0) / 100 }
    /// Omnipod-like table: 0.05 U/h steps up to 30 U/h.
    private let rates005 = (0 ... 600).map { Double($0) / 20 }

    private func seg(_ start: String, _ rate: String) -> R.Segment {
        R.Segment(start: start, rate: Decimal(string: rate)!)
    }

    private func validate(_ segments: [R.Segment], name: String = "Weekend", rates: [Double]? = nil,
                          maxBasal: Decimal = 2, dana: Bool = true) -> Result<[BasalProfileEntry], R.Rejection>
    {
        R.validate(name: name, segments: segments, supportedRates: rates ?? rates001, maxBasal: maxBasal, danaEncoding: dana)
    }

    private func entries(_ pairs: [(Int, String)]) -> [BasalProfileEntry] {
        pairs.map { BasalProfileEntry(start: String(format: "%02d:00:00", $0.0 / 60), minutes: $0.0, rate: Decimal(string: $0.1)!) }
    }

    // MARK: Decoding

    @Test("Payload decodes") func decodes() throws {
        let json = #"""
        {"user":"LoopFollow","command_type":"set_basal_schedule","timestamp":1790400000,
         "basal_schedule":[{"start":"00:00","rate":0.4},{"start":"02:00","rate":0.55}],
         "basal_schedule_name":"Weekend","expected_active_hash":"fd950334d8df0b65"}
        """#
        let payload = try JSONDecoder().decode(CommandPayload.self, from: Data(json.utf8))
        #expect(payload.commandType == .setBasalSchedule)
        #expect(payload.basalSchedule == [seg("00:00", "0.4"), seg("02:00", "0.55")])
        #expect(payload.basalScheduleName == "Weekend")
        #expect(payload.expectedActiveHash == "fd950334d8df0b65")
        #expect(TrioRemoteControl.CommandType.setBasalSchedule.rawValue == "set_basal_schedule")
        #expect(payload.humanReadableDescription().contains("Basal Schedule: Weekend, 2 segments."))
    }

    // MARK: Validation

    @Test("A valid schedule becomes storage entries") func validSchedule() throws {
        let result = try validate([seg("00:00", "0.4"), seg("02:00", "0.55"), seg("13:00", "0.4")]).get()
        #expect(result == [
            BasalProfileEntry(start: "00:00:00", minutes: 0, rate: Decimal(string: "0.4")!),
            BasalProfileEntry(start: "02:00:00", minutes: 120, rate: Decimal(string: "0.55")!),
            BasalProfileEntry(start: "13:00:00", minutes: 780, rate: Decimal(string: "0.4")!)
        ])
    }

    @Test("Segments must start on a whole hour", arguments: ["02:30", "02:01", "2:00", "24:00", "02", "aa:00", "02:00:00"])
    func notWholeHour(start: String) {
        #expect(throws: R.Rejection.self) { try validate([seg("00:00", "0.4"), seg(start, "0.5")]).get() }
    }

    @Test("First segment at 00:00, times strictly increasing, 1–24 segments") func shape() {
        #expect(throws: R.Rejection.self) { try validate([seg("01:00", "0.4")]).get() }
        #expect(throws: R.Rejection.self) { try validate([seg("00:00", "0.4"), seg("05:00", "0.5"), seg("03:00", "0.6")]).get() }
        #expect(throws: R.Rejection.self) { try validate([seg("00:00", "0.4"), seg("00:00", "0.5")]).get() }
        #expect(throws: R.Rejection.self) { try validate([]).get() }
        let all24 = (0 ..< 24).map { seg(String(format: "%02d:00", $0), "0.5") }
        #expect((try? validate(all24).get())?.count == 24)
    }

    @Test("Rate must be > 0, ≤ Max Basal and a supported value") func rates() {
        #expect(throws: R.Rejection.self) { try validate([seg("00:00", "0")]).get() }
        #expect(throws: R.Rejection.self) { try validate([seg("00:00", "2.05")], maxBasal: 2).get() }
        #expect((try? validate([seg("00:00", "2")], maxBasal: 2).get()) != nil)
        #expect(throws: R.Rejection.self) { try validate([seg("00:00", "0.555")]).get() } // not whole hundredths
        #expect(throws: R.Rejection.self) { try validate([seg("00:00", "0.42")], rates: rates005, dana: false).get() }
        #expect((try? validate([seg("00:00", "0.45")], rates: rates005, dana: false).get()) != nil)
    }

    @Test("Rates the Dana would store differently are rejected", arguments: ["0.29", "1.15", "2.05", "2.30"])
    func danaTruncation(rate: String) {
        #expect(throws: R.Rejection.self) { try validate([seg("00:00", rate)], maxBasal: 5).get() }
        // The same rate is fine for a pump without Dana's encoding (where the table allows it).
        #expect((try? validate([seg("00:00", rate)], maxBasal: 5, dana: false).get()) != nil)
    }

    /// 0.57 truncates when computed with a literal Double (0.57 * 100 = 56.999…), but Trio's Decimal → Double
    /// path (Double(truncating: Decimal as NSNumber)) yields a value that encodes to 57 — observed in CI — so it
    /// passes; the rule follows the real path, not the literal.
    @Test("Everyday Dana rates pass", arguments: ["0.4", "0.45", "0.55", "0.57", "0.6", "0.7", "1.0", "1.1", "1.2"])
    func danaGoodRates(rate: String) {
        #expect((try? validate([seg("00:00", rate)]).get()) != nil)
    }

    @Test("Name rules") func names() {
        #expect(throws: R.Rejection.self) { try validate([seg("00:00", "0.4")], name: "  ").get() }
        #expect(throws: R.Rejection.self) { try validate([seg("00:00", "0.4")], name: String(repeating: "a", count: 31)).get() }
        #expect(throws: R.Rejection.self) { try validate([seg("00:00", "0.4")], name: "a\"b").get() }
        #expect(throws: R.Rejection.self) { try validate([seg("00:00", "0.4")], name: "a\nb").get() }
        #expect((try? validate([seg("00:00", "0.4")], name: "Savaitgalis – žiema").get()) != nil)
    }

    // MARK: Hash and total (vectors shared with LoopFollow, see CUSTOMIZATIONS.md)

    @Test("Hash vectors") func hashVectors() {
        let child = entries([(0, "0.4"), (120, "0.55"), (180, "0.55"), (300, "0.6"), (360, "0.6"), (480, "0.6"),
                             (600, "0.7"), (780, "0.4"), (1140, "0.45")])
        #expect(R.hash(child) == "5c367b5397636149")
        #expect(R.hash(entries([(0, "1")])) == "946f8ef5ec7fc61e")
        #expect(R.hash(entries([(0, "0.35"), (420, "1.2"), (1320, "0.45")])) == "eabd566dccabc3e6")
        #expect(R.hash(entries([(0, "0.4"), (150, "0.5"), (300, "0.6")])) == "acff0d328fca2e73")
        // Order-independent and formatting-independent.
        #expect(R.hash(Array(child.reversed())) == "5c367b5397636149")
        #expect(R.hash(entries([(0, "1.00")])) == "946f8ef5ec7fc61e")
    }

    @Test("Hash depends on the schedule, not on how it is split") func hashIgnoresSplitting() {
        // [02:00 0.55, 03:00 0.55] == [02:00 0.55]
        #expect(R.hash(entries([(0, "0.4"), (120, "0.55"), (180, "0.55")])) == R.hash(entries([(0, "0.4"), (120, "0.55")])))
        #expect(R.hash(entries([(0, "0.4"), (120, "0.55")])) == "b692201fbdc3d38e")
        // Trio's stored child schedule (with repeats) == the merged form LoopFollow sends.
        let merged = entries([(0, "0.4"), (120, "0.55"), (300, "0.6"), (600, "0.7"), (780, "0.4"), (1140, "0.45")])
        #expect(R.hash(merged) == "5c367b5397636149")
        // A different schedule gives a different hash.
        #expect(R.hash(entries([(0, "0.4"), (120, "0.56")])) != "b692201fbdc3d38e")
    }

    @Test("A schedule with 30-minute segments hashes stably") func halfHourSegments() {
        let a = entries([(0, "0.4"), (150, "0.5"), (300, "0.6")])
        let b = entries([(300, "0.6"), (0, "0.4"), (150, "0.5"), (180, "0.5")])
        #expect(R.hash(a) == "acff0d328fca2e73")
        #expect(R.hash(b) == "acff0d328fca2e73")
        // 02:30 matters: moving it to 02:00 changes the hash.
        #expect(R.hash(entries([(0, "0.4"), (120, "0.5"), (300, "0.6")])) != "acff0d328fca2e73")
    }

    @Test("Daily total") func dailyTotal() {
        let child = entries([(0, "0.4"), (120, "0.55"), (180, "0.55"), (300, "0.6"), (360, "0.6"), (480, "0.6"),
                             (600, "0.7"), (780, "0.4"), (1140, "0.45")])
        #expect(R.dailyTotal(child) == Decimal(string: "12.2")!)
        #expect(R.dailyTotal(entries([(0, "1")])) == 24)
    }

    // MARK: Pre-checks

    @Test("Omnipod DASH is refused with the explanation") func omnipodRefused() {
        #expect(R.precheck(pump: .omnipod, suspended: false, bolusing: false, looping: false) == .message(R.omnipodRejection))
    }

    @Test("Only an idle Dana passes") func prechecks() {
        #expect(R.precheck(pump: .dana, suspended: false, bolusing: false, looping: false) == nil)
        #expect(R.precheck(pump: .dana, suspended: true, bolusing: false, looping: false) != nil)
        #expect(R.precheck(pump: .dana, suspended: false, bolusing: true, looping: false) != nil)
        #expect(R.precheck(pump: .dana, suspended: false, bolusing: false, looping: true) != nil)
        #expect(R.precheck(pump: .none, suspended: false, bolusing: false, looping: false) != nil)
        #expect(R.precheck(pump: .other, suspended: false, bolusing: false, looping: false) != nil)
    }
}
