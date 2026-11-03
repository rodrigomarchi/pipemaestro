# AGENTS.md — claude_control_plane

A SaaS that takes engineering tasks (GitHub issues) through a deterministic
pipeline of AI-agent stages up to a pull request ready for human review. The
product vision and architecture are in [`docs/plano/`](docs/plano/); read
[`01-visao-arquitetura.md`](docs/plano/01-visao-arquitetura.md) before any
non-trivial change.

## The umbrella and its boundaries

| App | Role | May depend on |
|---|---|---|
| `apps/claude_control_plane` | Control-plane domain: Ecto, pipeline engine, dispatcher, decisions. **No web layer.** | `protocol` |
| `apps/claude_control_plane_web` | Phoenix, LiveView board, Channels the runners connect to. The only place web concerns live. | domain, `protocol` |
| `apps/claude_control_plane_protocol` | The runner ↔ control-plane contract. Public and versioned. | nothing in the umbrella |
| `apps/claude_control_plane_runner` | The BYO runner installed on the customer's infrastructure. | `protocol` only |

The runner never depends on the domain or the web app: it ships as its own
release (`claude_control_plane_runner` in the root `mix.exs`) and must not carry
Phoenix or Ecto. Anything both sides need to agree on goes in `protocol`.

## Stack

Elixir and Erlang versions are pinned in `.tool-versions`; library versions live
in `mix.exs` and `mix.lock`. Postgres 16 runs in `docker-compose.yml` (dev on
port 5442, test on 5443). Technology choices and their reasons are in
[`docs/plano/02-contexto-discovery.md`](docs/plano/02-contexto-discovery.md) §3.

## The completion gate

**`make ci` is the gate for a change.** If it fails, the task is not complete.
It runs, cheapest first:

1. `mix compile --warnings-as-errors` — no warnings in our code, ever
2. `mix format --check-formatted`
3. `mix deps.unlock --check-unused`
4. `mix credo --strict`
5. `mix test --warnings-as-errors --cover` — each app has a 60% threshold
6. `mix dialyzer` — no ignore file; fix the type, do not silence it

`make ci.quick` is the same without Dialyzer, for iteration. `make help` lists
every target.

- **A pipe masks the exit code.** `make ci 2>&1 | tail` returns `tail`'s status.
  Use `make ci > log 2>&1; echo $?`.
- **Run `mix format` first.** It is the cheapest failure.
- **Every error found is yours to fix now**, regardless of who introduced it.

## Code conventions

- **Every public function has `@spec`.** Every module has `@moduledoc`
  (`@moduledoc false` for internals such as `Application`).
- **Alias on first write.** Credo enforces `AliasUsage`; do not wait for it.
- **LiveViews are thin**: they delegate to domain contexts and hold no business logic.
- **No silent catch.** A catch-all `handle_info` that eats a message you depend on
  is a swallowed exception.
- **Comments describe what the code does, never the change that produced it.**
- **Coverage exclusions are for code that cannot run in a test** (macro modules,
  `Application`, generated components) — never to get under the threshold.
- Phoenix 1.8 / LiveView idioms: [`docs/guias/phoenix.md`](docs/guias/phoenix.md).

## Documentation

- Product plan: `docs/plano/`, numbered in reading order.
- Architecture decisions: `docs/adr/NNNN-titulo-curto.md`, one per decision.
- Technical specs (protocol, pipeline schema, data model, state machines): `docs/specs/`.
- **Never write counts into prose** (modules, migrations, endpoints): they rot.
  Point at the directory instead.

## Git

- Stage exact paths — never `git add -A`.
- Never `git checkout <file>` to undo while other work is uncommitted.
