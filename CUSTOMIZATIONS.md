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

## 5. Considered and REJECTED

**Forced loop right after a remote mode change** (branch `feat/remote-mode-immediate-loop`, commit
`d5054fe`, deleted). Idea: call `apsManager.heartbeat(date:)` after the write so the new mode reaches
Nightscout at once. Rejected after review: when switching into Basal Testing,
`APSManager.settingsDidChange` cancels the Trio temp in its own `Task` while the forced loop may enact a
temp at the same moment (`basalTesting.automation == .hypoSuspendOnly`, so the loop does enact) — two
unordered temp-basal commands to the pump; a protective zero temp could be overwritten. Decision: Trio's
behaviour stays as upstream; the remote change is confirmed by the Trio push notification, and the new
mode reaches Nightscout with the next regular cycle.
