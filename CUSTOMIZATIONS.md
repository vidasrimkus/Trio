# CUSTOMIZATIONS — vidasrimkus/Trio

Every difference between this fork and upstream **nightscout/Trio v1.0.1** (`c0160aeaf`).
Read this first before any upstream update (procedure in `CLAUDE.md`).

## 1. Remote command `set_dosing_mode`

**Purpose.** Change Trio's Dosing Mode (Closed Loop / Open Loop / Low Glucose Suspend /
Basal Testing) remotely from LoopFollow through Trio Remote Control, the same way the other
remote commands (bolus, meal, temp target, override) already work.

**Commit.** `1d0aab415` — "Remote Control: add set_dosing_mode command".

**Files.**

| File | Change |
|---|---|
| `Trio/Sources/Models/CommandPayload.swift` | `CommandType.setDosingMode = "set_dosing_mode"` ("Set Dosing Mode"); field `dosingMode: String?` with CodingKey `"dosing_mode"`; computed `requestedDosingMode` (`DosingMode(rawValue:)`, nil when missing or unknown); `humanReadableDescription` names the mode. |
| `Trio/Sources/Services/RemoteControl/TrioRemoteControl+DosingMode.swift` | New. `handleSetDosingModeCommand` (@MainActor). |
| `Trio/Sources/Services/RemoteControl/TrioRemoteControl.swift` | `case .setDosingMode` in the command switch; `@Injected` `DeviceDataManager` and `FetchGlucoseManager` for the CGM/pump gate. |
| `Trio.xcodeproj/project.pbxproj` | Registers the new handler file (app target) and the new test file (TrioTests target). |
| `TrioTests/RemoteDosingModeCommandTests.swift` | New. Payload decoding for all four modes; unknown values (`teleportation`, `Closed`, `closed_loop`, `""`, `" open"`) and a missing `dosing_mode` rejected; `dosing_mode` ignored by other commands. |

**Handler behaviour** (`TrioRemoteControl+DosingMode.swift`), in order:

1. `dosing_mode` missing or not a `DosingMode` rawValue → `logError("Command rejected: invalid dosing mode")`, nothing changed.
2. No CGM or no pump → rejected with the missing part named. Same gate as the Settings picker (`Settings.StateModel.hasCgmAndPump()`).
3. Already in that mode → `logSuccess` "Already in X", nothing changed.
4. Otherwise `settings.settings.dosingMode = mode` on the main actor — the exact write the Settings
   picker makes (`BaseStateModel.subscribeSetting`), so every `SettingsObserver`
   (`APSManager.settingsDidChange`, e.g. cancelling a Trio temp when entering Basal Testing) runs as
   for a change made on the phone. Return notification: "Dosing mode: <old> → <new>".

Every path sends the return notification through the existing `logError` / `logSuccess` helpers.
Encryption, the timestamp window, the algorithm (`OpenAPS/`, `OpenAPSSwift/`),
`Preferences+DosingMode.swift` and all other remote commands are unchanged.

## 2. Fork CI

**Commit.** `1adbced30` — "ci(fork): run unit tests on demand in vidasrimkus/Trio".

`.github/workflows/unit_tests.yml`: added `workflow_dispatch`; removed
`if: github.repository_owner == 'nightscout'` from both jobs (`algorithm-package`, `test`).
Nothing else in the workflow changed. Run it with
`gh workflow run unit_tests.yml -R vidasrimkus/Trio --ref <branch>`.

## 3. Interfaces (other systems depend on these)

| Direction | Contract |
|---|---|
| LoopFollow → Trio | `vidasrimkus/LoopFollow` sends `command_type: "set_dosing_mode"` with `dosing_mode` = a `DosingMode` rawValue: `closed`, `open`, `lowGlucoseSuspend`, `basalTesting`. Encrypted exactly like the other TRC commands. Visible alert on the Trio phone: "Remote Command: Dosing Mode → <mode>". |
| Trio → LoopFollow | Result comes back only as the existing return push notification: title "Command Successful" / "Command Failed", body "Dosing mode: X → Y" or "Already in Y" (display names, localized; English on a Lithuanian phone). LoopFollow shows it as a notification; it does not parse it. |
| Trio → Nightscout → t1d-monitor, LoopFollow | Both read devicestatus `openaps.dosingMode` (set from `settingsManager.settings.dosingMode` at upload time, `NightscoutManager.swift`). The new mode appears there with the next loop cycle (≤ ~5 min). |
| LoopFollow → Trio (branch `feat/remote-basal-schedule`, not on main yet) | `command_type: "set_basal_schedule"` with `basal_schedule` = `[{"start":"HH:00","rate":<U/h>}]`, `basal_schedule_name`, `expected_active_hash` (§7). Result: return notification "Basal schedule activated: X (a → b U/d)", "Already active: X", or the error. Nightscout: the updated profile document (existing `uploadProfiles`) plus a Note "Basal schedule activated remotely: X (a → b U/d, <hash>)". |

If any of these contracts changes, `vidasrimkus/LoopFollow` and `t1d-monitor` must change too.

## 4. Browser Build (GitHub Actions → TestFlight)

- Repository variables: `SCHEDULED_SYNC=false` (the fork never syncs itself from upstream),
  `ENABLE_NUKE_CERTS=true`.
- Secrets: `TEAMID`, `FASTLANE_ISSUER_ID`, `FASTLANE_KEY_ID`, `FASTLANE_KEY`, `GH_PAT`, `MATCH_PASSWORD`
  (values live in 1Password only; `MATCH_PASSWORD` is shared with LoopFollow and encrypts `vidasrimkus/Match-Secrets`).
- Builds only from `main`. "4. Build Trio" also runs on its schedule (second Sunday of the month rebuilds `main`).
- Bundle `org.nightscout.B9R54LY699.trio`, Team `B9R54LY699` — the same bundle as the earlier Xcode build,
  so a TestFlight install replaces the app in place and keeps settings and pump/CGM pairing.
- First TestFlight build: 1.0.1 (2), 2026-09-26.

## 5. Pumps in use and Dana limitations (not changed by us — upstream/DanaKit behaviour)

Two pumps are used and swapped from time to time: **Dana** (DanaKit, `loopandlearn/DanaKit@a2d3aa4`) and
**Omnipod DASH** (OmnipodKit, `loopandlearn/OmnipodKit@4e923d7`). Facts read from the pinned driver sources:

1. **Trio's basal schedule is NOT written to a Dana when it is paired.** Trio passes its schedule as initial
   settings (`PumpConfigStateModel.swift:20-35`), DanaKit only stores it in its own state
   (`DanaUICoordinator.swift:74-76`). The only code that writes a schedule to the pump is
   `syncBasalRateSchedule` (`DanaKitPumpManager.swift:1091`), called only by Trio's Basal Profile editor.
   Until then the pump runs whatever profile it already had; Trio does not detect a difference
   (`syncDeliveryLimits` reads the pump's rates but keeps only `maxBasal`, `DanaKitPumpManager.swift:1199-1275`).
2. **Trio's temp basals reach a Dana as a percentage** of the schedule DanaKit holds
   (`absoluteBasalRateToPercentage`, `DanaKitPumpManager.swift:1359-1378`); the pump applies that
   percentage to its own active profile. If the two differ, every non-zero temp delivers a different
   amount than Trio intended (0 % temps are unaffected).
3. **Only whole-hour segments are safe on a Dana.** `convertBasal` (`DanaKitPumpManagerState.swift:390-407`)
   maps the schedule onto 24 hourly rates; a segment starting off the hour (e.g. 02:30) stops the index
   from advancing, so every later hour gets the previous rate on the pump. Trio's editor allows a
   30-minute grid, so this can happen from the phone too.
4. **Rates are encoded as `UInt16(rate * 100)`** (`DanaBasalSetProfileRate.swift`), which truncates some
   values by 0.01 U/h (e.g. 0.29 → 0.28; at 0.05 steps 1.15, 2.05, 2.30, 2.55, 4.10, 4.35, 4.60, 4.85).
5. Omnipod DASH, by contrast, stops all delivery (`cancelDelivery(.all)`) before programming a new schedule
   (`OmniPumpManager.swift:1834-1901`); a broken connection between the two steps leaves the pod suspended
   until it is resumed on the phone.

**Manual procedure after every Dana (re)connection** (new pairing, or back from Omnipod DASH):
Trio → Therapy → Basal Profile → change one value, Save, change it back, Save (Save stays disabled
without a change; each save writes the whole schedule to pump profile 0 and activates it). Then check on
the pump screen that the active profile's 24 hourly rates match Trio. t1d-monitor sends a Telegram
reminder when it sees a Dana connect (`dana-connected` rule).

## 6. Considered and REJECTED

**Forced loop right after a remote mode change** (branch `feat/remote-mode-immediate-loop`, commit
`d5054fe`, deleted). Idea: call `apsManager.heartbeat(date:)` after the write so the new mode reaches
Nightscout at once. Rejected after review: when switching into Basal Testing,
`APSManager.settingsDidChange` cancels the Trio temp in its own `Task` while the forced loop may enact a
temp at the same moment (`basalTesting.automation == .hypoSuspendOnly`, so the loop does enact) — two
unordered temp-basal commands to the pump; a protective zero temp could be overwritten. Decision: Trio's
behaviour stays as upstream; the remote change is confirmed by the Trio push notification, and the new
mode reaches Nightscout with the next regular cycle.

## 7. Remote command `set_basal_schedule` — Dana only (branch `feat/remote-basal-schedule`)

**Purpose.** Write a whole basal schedule to the pump and make it Trio's basal profile from LoopFollow.
Named profiles live in LoopFollow; Trio keeps its single `settings/basal_profile.json` as upstream.

**Files.** `Trio/Sources/Services/RemoteControl/RemoteBasalSchedule.swift` (new: pure rules),
`TrioRemoteControl+BasalSchedule.swift` (new: handler), `CommandPayload.swift` (`setBasalSchedule`,
`basal_schedule`, `basal_schedule_name`, `expected_active_hash`), `TrioRemoteControl.swift` (switch),
`project.pbxproj`, `TrioTests/RemoteBasalScheduleTests.swift`. No change to `APSManager`, `NightscoutManager`,
DanaKit or OmnipodKit.

**Order in the handler.**
1. Incomplete payload → rejected.
2. Pre-checks: pump must be a `DanaKitPumpManager` (Omnipod DASH → rejected with the explanation that the
   pod briefly stops all delivery and could not be resumed remotely; any other pump → rejected); not
   suspended/suspending/resuming; no bolus in progress (`bolusTrigger`); no loop running (`isLooping`).
   Nothing is queued — the sender retries.
3. Validation (`RemoteBasalSchedule.validate`): name 1–30 characters, no quotes or control characters;
   1–24 segments; first at 00:00; strictly increasing; **whole hours only** (`HH:00`); rate > 0 and ≤ Max
   Basal; rate a whole number of hundredths that is in the pump's `supportedBasalRates`; for a Dana,
   `UInt16(Double(rate) * 100)` must equal the hundredths (the Decimal → Double path the editor uses, then
   DanaKit's encoding) — otherwise rejected.
4. New schedule's hash == active hash → "Already active: X", nothing written (re-sending is safe). The hash
   is of what the schedule delivers, so this holds however either side splits it into entries.
5. `expected_active_hash` ≠ active hash → rejected ("the active basal schedule changed since it was read").
6. Write through the Basal Profile editor's own path, `BasalProfileEditor.Provider.saveProfile` (pump first,
   local file only on success). On failure nothing is saved in Trio and the error reads
   "Pompa galėjo priimti dalį pakeitimų. Pakartokite tą patį aktyvavimą arba patikrinkite pompą." — the
   expected hash is still the old active one, so the same command can simply be sent again.
7. On success the editor's follow-up: `basalProfileDidChange` broadcast, Nightscout `uploadProfiles`, Tidepool
   settings; plus a Nightscout Note "Basal schedule activated remotely: X (a → b U/d, <hash>)".

**Schedule hash (shared with LoopFollow) — depends on the schedule, not on how it is split.**
1. Sort the entries by start (minutes from midnight).
2. For each of the 48 half-hours `slot = 0 … 47` (minute `slot × 30`: 00:00, 00:30, … 23:30), take the rate of
   the entry with the latest start ≤ that minute; if there is none (schedule not starting at 00:00), take the
   last entry (a daily schedule wraps).
3. Convert each rate to whole hundredths of U/h: `rate × 100`, rounded half-up to an integer (Trio: Decimal
   `NSDecimalRound(.plain)`; LoopFollow: the same on Decimal, or `Int((rate × 100).rounded())` for Nightscout
   doubles — identical for 2-decimal rates).
4. Join the 48 integers with `;` (no spaces, no trailing separator).
5. Hash = lowercase hex of the first 8 bytes of SHA-256 over the UTF-8 bytes of that string (16 hex characters).

Works for any stored schedule, including one with 30-minute segments saved on the phone (which
`set_basal_schedule` itself does not accept). Vectors (tested in Trio `RemoteBasalScheduleTests` and LoopFollow
`BasalProfileTests`):

| Schedule | Canonical (48 values) | Hash | Daily total |
|---|---|---|---|
| V1: 00:00 0.40, 02:00 0.55, 03:00 0.55, 05:00 0.60, 06:00 0.60, 08:00 0.60, 10:00 0.70, 13:00 0.40, 19:00 0.45 | 40×4, 55×6, 60×10, 70×6, 40×12, 45×10 | `5c367b5397636149` | 12.2 U |
| V1 merged: 00:00 0.40, 02:00 0.55, 05:00 0.60, 10:00 0.70, 13:00 0.40, 19:00 0.45 | same | `5c367b5397636149` | 12.2 U |
| V2: 00:00 1.00 | 100×48 | `946f8ef5ec7fc61e` | 24 U |
| V3: 00:00 0.35, 07:00 1.20, 22:00 0.45 | 35×14, 120×30, 45×4 | `eabd566dccabc3e6` | — |
| V4 (30-min segment): 00:00 0.40, 02:30 0.50, 05:00 0.60 | 40×5, 50×5, 60×38 | `acff0d328fca2e73` | — |
| V5: 00:00 0.40, 02:00 0.55 (= 00:00 0.40, 02:00 0.55, 03:00 0.55) | 40×4, 55×44 | `b692201fbdc3d38e` | — |

("40×4" = the value 40 repeated in 4 consecutive slots.)
