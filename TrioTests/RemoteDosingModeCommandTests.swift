import Foundation
import Testing
@testable import Trio

@Suite("Remote set_dosing_mode command") struct RemoteDosingModeCommandTests {
    /// The decrypted JSON a sender (e.g. LoopFollow) puts inside `encrypted_data`.
    private func decode(_ json: String) throws -> CommandPayload {
        try JSONDecoder().decode(CommandPayload.self, from: Data(json.utf8))
    }

    private func payloadJSON(dosingMode: String?) -> String {
        let field = dosingMode.map { #", "dosing_mode": "\#($0)""# } ?? ""
        return #"{"user": "LoopFollow", "command_type": "set_dosing_mode", "timestamp": 1790400000\#(field)}"#
    }

    @Test("Command type raw value and description") func commandType() {
        #expect(TrioRemoteControl.CommandType.setDosingMode.rawValue == "set_dosing_mode")
        #expect(TrioRemoteControl.CommandType.setDosingMode.description == "Set Dosing Mode")
    }

    @Test("Every DosingMode rawValue decodes to that mode", arguments: DosingMode.allCases)
    func everyModeDecodes(mode: DosingMode) throws {
        let payload = try decode(payloadJSON(dosingMode: mode.rawValue))
        #expect(payload.commandType == .setDosingMode)
        #expect(payload.dosingMode == mode.rawValue)
        #expect(payload.requestedDosingMode == mode)
        #expect(payload.humanReadableDescription().contains("Dosing Mode: \(mode.displayName)."))
    }

    @Test("The four wire values are exactly the ones the sender uses") func wireValues() {
        #expect(DosingMode.allCases.map(\.rawValue).sorted() == ["basalTesting", "closed", "lowGlucoseSuspend", "open"])
    }

    @Test("An unknown mode is rejected", arguments: ["teleportation", "Closed", "closed_loop", "", " open"])
    func invalidModeRejected(value: String) throws {
        let payload = try decode(payloadJSON(dosingMode: value))
        #expect(payload.requestedDosingMode == nil)
        #expect(payload.humanReadableDescription().contains("Dosing Mode: invalid"))
    }

    @Test("A command without dosing_mode is rejected") func missingModeRejected() throws {
        let payload = try decode(payloadJSON(dosingMode: nil))
        #expect(payload.dosingMode == nil)
        #expect(payload.requestedDosingMode == nil)
    }

    @Test("dosing_mode is ignored by the other commands") func otherCommandsUnaffected() throws {
        let payload = try decode(#"{"user": "x", "command_type": "cancel_override", "timestamp": 1, "dosing_mode": "closed"}"#)
        #expect(payload.commandType == .cancelOverride)
        #expect(!payload.humanReadableDescription().contains("Dosing Mode"))
    }
}
