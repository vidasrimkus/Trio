# set_carb_ratios / set_isf — deferred work

Review findings not fixed (CLAUDE.md rule 8: none of them can disturb dosing, lose or corrupt data, or leak
secrets). Code: `Trio/Sources/Services/RemoteControl/RemoteTherapySchedule.swift` and the two handlers; behaviour in
`CUSTOMIZATIONS.md` §11.

- **Finding 3 — a malformed segment fails decoding of the whole payload, so no return notification is sent.** Not
  fixed: nothing is written (fails safe), LoopFollow builds the payload from typed values, and `set_basal_schedule`
  behaves the same; a fix would mean lenient decoding in `CommandPayload` for all three commands.
- **Finding 4 — if LoopFollow parsed Nightscout values as Double, its hash could differ and Trio would reject.** Not
  fixed: a mismatch only refuses the command ("changed since it was read"), it never writes a wrong schedule; the
  contract tells LoopFollow to round half-up from the decimal values, and the shared vectors test it.
