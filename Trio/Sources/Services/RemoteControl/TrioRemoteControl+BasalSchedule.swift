import DanaKit
import Foundation
import LoopKit
import OmnipodKit

extension TrioRemoteControl {
    /// `set_basal_schedule`: write a whole basal schedule to a Dana and make it Trio's basal profile.
    /// Rules live in RemoteBasalSchedule; the pump write and the local save are the Basal Profile editor's own
    /// (BasalProfileEditor.Provider.saveProfile: pump first, local file only on success), followed by the same
    /// notifications and uploads the editor's save performs.
    @MainActor func handleSetBasalScheduleCommand(_ payload: CommandPayload) async {
        guard let segments = payload.basalSchedule, let name = payload.basalScheduleName,
              let expectedHash = payload.expectedActiveHash
        else {
            await logError("Command rejected: basal schedule data is incomplete.", payload: payload)
            return
        }

        let pump = deviceDataManager.pumpManager
        let kind: RemoteBasalSchedule.PumpKind = {
            guard let pump else { return .none }
            if pump is DanaKitPumpManager { return .dana }
            if pump is OmniPumpManager { return .omnipod }
            return .other
        }()
        let suspended: Bool = {
            switch pump?.status.basalDeliveryState {
            case .suspending?, .suspended?, .resuming?: return true
            default: return false
            }
        }()
        let aps = TrioApp.resolver.resolve(APSManager.self)
        if let rejection = RemoteBasalSchedule.precheck(
            pump: kind,
            suspended: suspended,
            bolusing: deviceDataManager.bolusTrigger.value != .noBolus,
            looping: aps?.isLooping.value ?? false
        ) {
            await logError("Command rejected: \(rejection.text)", payload: payload)
            return
        }

        let provider = BasalProfileEditor.Provider(resolver: TrioApp.resolver)
        let pumpSettings = provider.storage.retrieve(OpenAPS.Settings.settings, as: PumpSettings.self)
            ?? PumpSettings(from: OpenAPS.defaults(for: OpenAPS.Settings.settings))
            ?? PumpSettings(insulinActionCurve: 10, maxBolus: 10, maxBasal: 2)

        let entries: [BasalProfileEntry]
        switch RemoteBasalSchedule.validate(
            name: name,
            segments: segments,
            supportedRates: pump?.supportedBasalRates ?? [],
            maxBasal: pumpSettings.maxBasal,
            danaEncoding: kind == .dana
        ) {
        case let .success(valid): entries = valid
        case let .failure(rejection):
            await logError("Command rejected: \(rejection.text)", payload: payload)
            return
        }

        let current = provider.profile
        let activeHash = RemoteBasalSchedule.hash(current)
        let newHash = RemoteBasalSchedule.hash(entries)
        let oldTotal = Self.unitsText(RemoteBasalSchedule.dailyTotal(current))
        let newTotal = Self.unitsText(RemoteBasalSchedule.dailyTotal(entries))

        // Re-sending the schedule that is already active is safe and changes nothing.
        guard newHash != activeHash else {
            await logSuccess(
                "Remote command processed successfully. Basal schedule \"\(name)\" is already active (\(newHash)).",
                payload: payload,
                customNotificationMessage: "Already active: \(name)"
            )
            return
        }
        guard expectedHash == activeHash else {
            await logError(
                "Command rejected: the active basal schedule changed since it was read (expected \(expectedHash), active \(activeHash)). Refresh and try again.",
                payload: payload
            )
            return
        }

        do {
            for try await _ in provider.saveProfile(entries).values {}
        } catch {
            // Nothing was saved in Trio; the pump may already hold the new rates. Re-sending the same schedule
            // is safe (the expected hash is still the old active one).
            await logError(
                "Command failed: \(RemoteBasalSchedule.partialWriteMessage) (\(error.localizedDescription))",
                payload: payload
            )
            return
        }

        // Same follow-up as BasalProfileEditor.StateModel.save() after a successful save.
        let broadcaster = TrioApp.resolver.resolve(Broadcaster.self)
        broadcaster?.notify(BasalProfileObserver.self, on: .main) { $0.basalProfileDidChange(entries) }
        let nightscout = nightscoutManager
        Task.detached(priority: .low) {
            do { try await nightscout?.uploadProfiles() } catch {
                debug(.default, "Failed to upload basal rates to Nightscout: \(error)")
            }
        }
        if let tidepool = TrioApp.resolver.resolve(TidepoolManager.self) {
            Task.detached(priority: .low) { await tidepool.uploadSettings() }
        }
        await nightscoutManager.uploadNoteTreatment(
            note: "Basal schedule activated remotely: \(name) (\(oldTotal) → \(newTotal) U/d, \(newHash))"
        )

        await logSuccess(
            "Remote command processed successfully. Basal schedule \"\(name)\" activated (\(activeHash) → \(newHash)).",
            payload: payload,
            customNotificationMessage: "Basal schedule activated: \(name) (\(oldTotal) → \(newTotal) U/d)"
        )
    }

    private static func unitsText(_ value: Decimal) -> String {
        var input = value
        var rounded = Decimal()
        NSDecimalRound(&rounded, &input, 2, .plain)
        return "\(rounded)"
    }
}
