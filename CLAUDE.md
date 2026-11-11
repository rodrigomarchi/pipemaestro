@AGENTS.md

# Claude Code

`AGENTS.md` above is the canonical instruction set, shared with every other agent.
This section is only what is specific to Claude Code.

## Working preferences

- **Use plan mode** for changes spanning more than one app of the umbrella, and for
  anything touching the runner ↔ control-plane protocol.
- **Validate targeted while iterating, `make ci` at the end of a functional block** —
  not after every edit, and never again on a tree that already passed (see "Verify
  what the change touches, once" in `AGENTS.md`).
- **Every error found is yours to fix now**, regardless of which session introduced it.
- **Every decision or ambiguity for the user goes through the interactive questionnaire**
  (`AskUserQuestion`): before, during and at the end of a task, commit and PR included.
  Never ask in prose, and never end a summary with a question in text.
