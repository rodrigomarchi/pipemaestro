.PHONY: help setup deps docker.up docker.down docker.reset server iex \
	test test.cover format format.check credo dialyzer deps.check lint ci ci.quick \
	runner.login runner.start runner.status runner.logout \
	e2e.install e2e.db e2e.db.reset e2e.assets e2e e2e.headed e2e.ui e2e.shots e2e.typecheck

E2E_PORT ?= 4003
E2E_MIX   = MIX_ENV=e2e E2E_PORT=$(E2E_PORT) mix
E2E_ENV   = E2E_PORT=$(E2E_PORT)

.DEFAULT_GOAL := help

help: ## Show this help
	@grep -E '^[a-zA-Z0-9_.-]+:.*?## ' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

# ── Setup ────────────────────────────────────────────────────────────────────

setup: docker.up ## First-time setup (Postgres containers + deps + database + assets)
	mix setup

deps: ## Install Elixir dependencies
	mix deps.get

docker.up: ## Start the dev and test Postgres containers
	docker compose up -d --wait

docker.down: ## Stop and remove the Postgres containers
	docker compose down

docker.reset: ## Destroy the containers and their volumes
	docker compose down -v

# ── Run ──────────────────────────────────────────────────────────────────────

server: ## Start the Phoenix dev server
	mix phx.server

iex: ## Start the Phoenix dev server inside IEx
	iex -S mix phx.server

# ── Tests ────────────────────────────────────────────────────────────────────

test: ## Run the whole suite
	mix test --warnings-as-errors

test.cover: ## Run the whole suite with the per-app coverage threshold
	mix test --warnings-as-errors --cover

# ── Static analysis ──────────────────────────────────────────────────────────

format: ## Format every source file
	mix format

format.check: ## Fail when a file is not formatted
	mix format --check-formatted

credo: ## Run Credo in strict mode
	mix credo --strict

dialyzer: ## Run Dialyzer
	mix dialyzer

deps.check: ## Fail when mix.lock carries an unused dependency
	mix deps.unlock --check-unused

lint: format.check credo deps.check dialyzer ## Run every static check

# ── Gate ─────────────────────────────────────────────────────────────────────

# `make ci` is the gate for a change: a change is not done while it fails.
# Order is cheapest first, so a formatting slip fails before the suite runs.
ci: ci.quick dialyzer ## Run every check and the whole suite with coverage

ci.quick: ## Run every check but Dialyzer (iteration only)
	MIX_ENV=test mix compile --warnings-as-errors --force
	mix format --check-formatted
	mix deps.unlock --check-unused
	mix credo --strict
	mix test --warnings-as-errors --cover

# ── Runner ──────────────────────────────────────────────────────────────────

# The runner's tasks run inside its own app, so the control plane does not boot
# along with them. Credentials go to ~/.config/claude-control-plane (or
# RUNNER_CONFIG_DIR).
RUNNER_DIR = apps/claude_control_plane_runner

runner.login: ## Sign this machine in as a runner (URL=http://localhost:4000 [NAME=...] [LABELS="gpu cuda"] [CAPACITY=N])
	@test -n "$(URL)" || { echo "usage: make runner.login URL=http://localhost:4000"; exit 2; }
	cd $(RUNNER_DIR) && mix runner.login --url $(URL) $(if $(NAME),--name "$(NAME)") \
		$(foreach label,$(LABELS),--label $(label)) $(if $(CAPACITY),--capacity $(CAPACITY))

runner.start: ## Connect this runner and stay online (Ctrl+C to stop)
	cd $(RUNNER_DIR) && mix runner.start

runner.status: ## Show this runner's credentials and whether the platform accepts them
	cd $(RUNNER_DIR) && mix runner.status

runner.logout: ## Remove this runner's saved credentials
	cd $(RUNNER_DIR) && mix runner.logout

# ── Browser E2E (Playwright) ────────────────────────────────────────────────

# A real browser against MIX_ENV=e2e on E2E_PORT, with its own database. Specs
# create their own data through the UI; see e2e/README.md.

e2e.install: ## First time: install the e2e npm deps and Chromium
	cd e2e && npm install && npx playwright install chromium

e2e.db.reset: ## Drop and recreate the e2e database (stops the server on E2E_PORT first)
	@pids=$$(lsof -ti:$(E2E_PORT) 2>/dev/null); [ -z "$$pids" ] || kill -9 $$pids
	$(E2E_MIX) ecto.drop --quiet
	$(E2E_MIX) ecto.create --quiet
	$(E2E_MIX) ecto.migrate --quiet

# Before the server boots: Playwright starts it ahead of global-setup.ts.
e2e.db: ## Create and migrate the e2e database if needed
	$(E2E_MIX) ecto.create --quiet
	$(E2E_MIX) ecto.migrate --quiet

e2e.assets: ## Build the CSS and JS the e2e server serves
	cd apps/claude_control_plane_web && MIX_ENV=e2e mix assets.build

# The server is restarted on every run: playwright.config.ts reuses whatever is
# on the port, and a server left from before a fix would validate the old code.
e2e: e2e.db e2e.assets ## Run the whole suite headless (FILE=tests/x.spec.ts for one spec)
	@pids=$$(lsof -ti:$(E2E_PORT) 2>/dev/null); [ -z "$$pids" ] || kill -9 $$pids
	cd e2e && $(E2E_ENV) npx playwright test $(FILE)

e2e.headed: e2e.db e2e.assets ## Run with a visible browser and slow motion (FILE=..., SLOW_MO=300)
	@pids=$$(lsof -ti:$(E2E_PORT) 2>/dev/null); [ -z "$$pids" ] || kill -9 $$pids
	cd e2e && $(E2E_ENV) SLOW_MO=$${SLOW_MO:-300} npx playwright test --headed $(FILE)

e2e.ui: e2e.db e2e.assets ## Open the Playwright UI mode
	cd e2e && $(E2E_ENV) npx playwright test --ui

e2e.shots: e2e.db e2e.assets ## Run the suite capturing visual evidence, light and dark (FILE=... for one spec)
	@pids=$$(lsof -ti:$(E2E_PORT) 2>/dev/null); [ -z "$$pids" ] || kill -9 $$pids
	rm -rf e2e/screenshots
	cd e2e && $(E2E_ENV) E2E_SHOTS=1 E2E_SHOTS_DARK=$${DARK:-1} npx playwright test $(FILE)
	@echo "Evidence: e2e/screenshots/<spec>/<test>/  (HTML report: cd e2e && npx playwright show-report)"

e2e.typecheck: ## Typecheck the specs, page objects and helpers
	cd e2e && npx tsc --noEmit
