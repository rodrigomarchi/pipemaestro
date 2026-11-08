# AGENTS.md — PipeMaestro

A SaaS that takes engineering tasks (GitHub issues) through a deterministic
pipeline of AI-agent stages up to a pull request ready for human review. The
product vision and architecture are in [`docs/plano/`](docs/plano/); read
[`01-visao-arquitetura.md`](docs/plano/01-visao-arquitetura.md) before any
non-trivial change.

## The umbrella and its boundaries

| App | Role | May depend on |
|---|---|---|
| `apps/pipe_maestro` | Control-plane domain: `Accounts` (workspace users), `Backoffice` (operators), `Workspaces`, `Runners` (device flow, runner tokens), `RunnerTelemetry` (a runner's connections, health, log and diagnosis, ADR 0039), `Jobs` (prompts sent to a runner, their events and outcome), `Pipelines` (stages kept per workspace, with their gates and rules), `Projects` (setup, test and lint commands per code directory), `Tasks` (a prompt worked through a pipeline's stages, the gate and decisions), `Usage`, `Insights` (how the agent worked, for auditing), `Audit`, `Secrets` (encrypted, handed to runners per job), `Authorization` (admin and member roles), `Integrations` (git hosts: Forgejo and GitHub connections, linked repositories, issue triggers, webhook deliveries and the feedback on issues and pull requests), `Notifications` (each person's inbox and what runs now, ADR 0044) and `Maintenance` (periodic housekeeping); later the dispatcher. **No web layer.** | `protocol` |
| `apps/pipe_maestro_web` | Phoenix, LiveView board, Channels the runners connect to. The only place web concerns live. | domain, `protocol` |
| `apps/pipe_maestro_protocol` | The runner ↔ control-plane contract (`Hello`, `Job`, `JobEvent`, paths, topics, versions). Public and versioned: [`docs/specs/protocolo-runner.md`](docs/specs/protocolo-runner.md). | nothing in the umbrella |
| `apps/pipe_maestro_runner` | The BYO runner: `runner.*` Mix tasks (device-flow login, Slipstream connection), and `JobRunner`, which runs jobs with the `claude` CLI, a task's stages in a git worktree of a directory under the runner's root. Run its tasks from its own directory (`make runner.*`), never from the root. | `protocol` only |

The runner never depends on the domain or the web app: it ships as its own
release (`pipe_maestro_runner` in the root `mix.exs`) and must not carry
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

`make ci.quick` is the same without Dialyzer. `make help` lists every target.

**Screen changes also need `make e2e`** (Playwright, real browser; see
[`e2e/README.md`](e2e/README.md)). Use `make e2e.shots FILE=...` to capture light
and dark screenshots of a flow and audit them; never drive a browser by hand to
check a screen.

- **A pipe masks the exit code.** `make ci 2>&1 | tail` returns `tail`'s status.
  Use `make ci > tmp/ci.log 2>&1; echo $?`.
- **Logs go to `tmp/`** (ignored, inside the checkout), never `/tmp/`: other
  worktrees run at once and would read or overwrite each other's log.
- **Run `mix format` first.** It is the cheapest failure.
- **Every error found is yours to fix now**, regardless of who introduced it.

### Verify what the change touches, once

The whole suite is the gate's job, not the loop's
([ADR 0046](docs/adr/0046-verificacao-por-arvore.md)):

- **While iterating, run the tests the change touches**: the file
  (`mix test path/to/x_test.exs`), the app (`cd apps/<app> && mix test`) or
  `mix test --failed` after a fix. Never the umbrella's suite after each edit.
- **The whole suite at most once, at the end**, and only if code changed since it
  last passed. `make ci`, `make ci.quick`, `make test.cover` and `make e2e` run
  once per tree: on a tree that already passed they say so and stop (`FORCE=1`
  runs them anyway). Re-running them only to see the same answer is wasted time.
- **e2e while iterating: one spec** (`make e2e FILE=tests/x.spec.ts`, or
  `cd e2e && npx playwright test --only-changed=origin/main`). The whole e2e
  suite runs once, when the screens are done. Changes outside screens
  (`apps/pipe_maestro_web/lib`, `assets/`, `e2e/`) do not need e2e.
- **Docs-only changes need no suite.**
- **A failing check you did not cause still is yours** (the rule above), but fix
  it where it fails and re-run that test, not the whole gate.

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
- **UI is petal_components.** Use a Petal component before raw Tailwind markup, and
  check its real attrs first: [`docs/guias/ui-petal.md`](docs/guias/ui-petal.md).
- **Every element a test touches has a `data-testid`**, named per
  [`e2e/README.md`](e2e/README.md) (per-record ids carry the natural key: e-mail
  or slug). Specs select by test id only.
- **Verify screens visually** through `make e2e.shots`, light and dark, before
  calling UI work done.

## Documentation

- Product plan: `docs/plano/`, numbered in reading order.
- Architecture decisions: `docs/adr/NNNN-titulo-curto.md`, one per decision.
- Technical specs (protocol, pipeline schema, data model, state machines): `docs/specs/`.
- **Never write counts into prose** (modules, migrations, endpoints): they rot.
  Point at the directory instead.

## Git

- **`main` only changes through pull requests**: the Forgejo refuses direct pushes,
  admins included. Work on a branch, push it and open a PR; merging it deploys
  (`.forgejo/workflows/deploy.yml`, [`docs/guias/deploy.md`](docs/guias/deploy.md)).
- Stage exact paths — never `git add -A`.
- Never `git checkout <file>` to undo while other work is uncommitted.
