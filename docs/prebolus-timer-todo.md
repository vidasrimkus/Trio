# Pre-bolus timer — open items (not blocking the build)

- The row plans at its once-a-minute tick, `arm` plans again after Face ID; a CGM reading arriving in between can
  make the scheduled wait differ from the one shown (e.g. 10 vs 15 min). The Home countdown shows the real one.
  Reason: rare, never longer than the cap, the countdown is authoritative.
- `apsManager.enactBolus` returns without calling the callback when the amount is ≤ 0 (Max Bolus 0): the timer
  stays armed with no bolus. Reason: needs Max Bolus = 0; `addPumpInsulin` already guards amount > 0.
- ~~`deadline` is in memory only~~ — v2 keeps the armed timer in UserDefaults; a relaunch restores the countdown.
- Decided 2026-11-03: a pump error after the command (`APSError.pumpError`, delivery uncertain) KEEPS the
  reminder; only failures before the pump (pre-checks, no pump) remove it. A pump that rejects a bolus outright
  therefore also keeps it (reminder with no insulin → high, not hypo). Reason: the safer direction.
- A bolus cancelled outside Trio's two Cancel buttons (pump manager UI, the pump's own button) leaves the timer
  armed: the reminder comes on time with less insulin given. Reason: the safer direction (high, not hypo); the
  progress-based detection that caught it was removed because it also fired after full delivery.
- Placement of the Home countdown (bottom of the 44 pt meal-panel slot, caption2) is unverified without a
  simulator — check on the TestFlight build. Reason: visual only.

## v2

- Silent reminder: that `prebolus_silent.caf` makes the phone vibrate (locked, unlocked, Ring/Silent switch) is
  unverified — check on the TestFlight build. If it does not vibrate the setting still works as "visual only", as
  its footer says.
- `meal_started via=timer` from the background arrives at the end of the next loop cycle (≤ ~5 min late; `at` is
  exact). With the loop stuck (as on 2026-11-03 13:05) it waits until the app is opened. Reason: no extra
  background work for a Note.
- The silent setting applies from the next timer; a timer already armed keeps its sound. Reason: rare, harmless.

### Evaluated and rejected (2026-11-03): move the carb entry's time to the meal start on "Valgau"

- What it would take: Trio has no in-place carb update; History edit (`HistoryStateModel+CarbEditing.swift`)
  deletes the entry (and its whole `fpuID` group) and stores a new one with a new UUID, then `uploadCarbs` to
  Nightscout / HealthKit / Tidepool and `determineBasalSync`. That code lives inside the History module, so Home
  would need it extracted or duplicated, plus the carb entry's objectID linked at arm time — changes in upstream
  `TreatmentsStateModel`, `CarbsStorage` and `NightscoutManager.deleteCarbs`.
- Nightscout: delete by id + upload of a new document. A failed delete (no network) leaves a duplicate in NS
  (Trio's loop reads local Core Data, but NS reports and t1d-monitor analyses would count the carbs twice).
- oref COB: starts at the carb time; while waiting, BG falls (insulin, no food) so only the minimum absorption is
  assumed — 8 mg/dL per 5 min, i.e. ~0.8 g per 5 min at ISF 42 / CR 4, ~2–3 g over a 15 min wait (~8 % of a
  32 g meal). Re-dating would restore that — a small dosing effect.
- IOB: unchanged (insulin records untouched). Between the delete and the new entry a loop can run with 0 carbs and
  a large IOB (less insulin — the safe direction, but noise); History shows the moved time; FPU groups are
  recreated whole; rebase risk in the upstream files above.
- Decision: NO. `meal_started` already gives the real meal start for analysis without touching therapy data.
  Revisit only if analysis shows the COB model systematically wrong after long (> 20 min) waits.
