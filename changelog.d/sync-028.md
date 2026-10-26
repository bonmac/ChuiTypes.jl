- Synced the ecosystem factory template 0.2.7 -> 0.2.8 (see `.factory-version`): the lane cap
  (`dispatch_limit.sh`) now counts Agent dispatches instead of SubagentStart/Stop, which never
  balanced for teammates, so `[lanes] max_open` fires again. Lanes close on a completed or failed
  Agent result, a `TaskStop`, auto mode's denial, or a background agent's SubagentStop; a new
  managed hook library `.claude/hooks/_lanes.sh` does the counting under a lock
  (`.lanes/.dispatch.lock`).
- `scripts/lane release <name>` closes a lane whose agent is gone.
- The hook ledger starts a new line after a truncated last line instead of losing the next record.
- `docs/CHECK_COVERAGE.md` and the `lane-lifecycle` skill list the new blind spots and how lanes
  open and close.
