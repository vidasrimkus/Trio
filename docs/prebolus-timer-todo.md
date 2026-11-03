# Pre-bolus timer — open items (not blocking the build)

- The row plans at its once-a-minute tick, `arm` plans again after Face ID; a CGM reading arriving in between can
  make the scheduled wait differ from the one shown (e.g. 10 vs 15 min). The Home countdown shows the real one.
  Reason: rare, never longer than the cap, the countdown is authoritative.
- `apsManager.enactBolus` returns without calling the callback when the amount is ≤ 0 (Max Bolus 0): the timer
  stays armed with no bolus. Reason: needs Max Bolus = 0; `addPumpInsulin` already guards amount > 0.
- `deadline` is in memory only: after an app relaunch the Home countdown is gone while the notification still
  fires. Reason: the notification (the part that matters) survives.
- A pump error with uncertain delivery (e.g. Omnipod) goes through `callback(false)` and removes the reminder
  although insulin may have been delivered; "Bolus failed — check pump history" is shown by APSManager.
  Decide with Vidas whether failures should keep the reminder. Reason: spec says remove on failure.
- A bolus cancelled outside Trio's two Cancel buttons (pump manager UI, the pump's own button) leaves the timer
  armed: the reminder comes on time with less insulin given. Reason: the safer direction (high, not hypo); the
  progress-based detection that caught it was removed because it also fired after full delivery.
- Placement of the Home countdown (bottom of the 44 pt meal-panel slot, caption2) is unverified without a
  simulator — check on the TestFlight build. Reason: visual only.
