@AGENTS.md

# Claude Code

`AGENTS.md` above is the canonical instruction set, shared with every other agent.
This section is only what is specific to Claude Code.

## Working preferences

- **Use plan mode** for changes spanning more than one app of the umbrella, and for
  anything touching the runner ↔ control-plane protocol.
- **Validate targeted while iterating, `make ci` at the end of a functional block** —
  not after every edit.
- **Every error found is yours to fix now**, regardless of which session introduced it.
