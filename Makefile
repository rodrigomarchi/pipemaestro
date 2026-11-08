.PHONY: help setup deps docker.up docker.down docker.reset db.migrate db.rollback server iex \
	test test.cover format format.check credo dialyzer deps.check lint ci ci.quick \
	runner.login runner.start runner.doctor runner.service runner.release runner.install image \
	deploy deploy.skip-ci \
	runner.status runner.logout runner.binary runner.rel runner.version cp.version \
	e2e.install e2e.db e2e.db.reset e2e.assets e2e e2e.headed e2e.ui e2e.shots e2e.typecheck \
	landing.shots

# Burrito's single binary sets __BURRITO, and the runner app boots as the CLI when it
# sees it. Commands started by the binary (the agent's shell in a job) inherit it, so
# every recipe drops it: nothing here runs inside the binary.
unexport __BURRITO

# Deploy settings (DEPLOY_USER, SUN_IP, ...) live in an untracked .env; see .env.example.
-include .env
export DEPLOY_USER SUN_IP SSH_PORT DEPLOY_URL

# A git worktree (each task of the control plane runs in one) gets its own e2e
# port, derived from its name, so tasks running at once never stop each other's
# server; its databases are apart too (config/worktree.exs).
WORKTREE := $(shell sed -n 's|^gitdir: .*/||p' .git 2>/dev/null | tr -dc 'a-z0-9' | cut -c1-8)
E2E_PORT ?= $(if $(WORKTREE),$(shell echo $$(( 4100 + $$(printf %s '$(WORKTREE)' | cksum | cut -d' ' -f1) % 800 ))),4003)
# The fake git hosts the suite starts (e2e/helpers/fakeForgejo.ts, fakeGitHub.ts)
# follow the same port, so two suites at once never fight over them either.
E2E_FORGEJO_PORT ?= $(shell echo $$(( $(E2E_PORT) + 1000 )))
E2E_GITHUB_PORT  ?= $(shell echo $$(( $(E2E_PORT) + 2000 )))
E2E_PORTS = E2E_PORT=$(E2E_PORT) E2E_FORGEJO_PORT=$(E2E_FORGEJO_PORT) E2E_GITHUB_PORT=$(E2E_GITHUB_PORT)
E2E_MIX   = MIX_ENV=e2e $(E2E_PORTS) mix
E2E_ENV   = $(E2E_PORTS)

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

db.migrate: ## Run pending migrations on the dev database
	mix ecto.migrate

db.rollback: ## Roll back the last migration on the dev database (STEP=n for more)
	mix ecto.rollback --step $${STEP:-1}

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
# along with them. Credentials go to ~/.config/pipemaestro (or
# RUNNER_CONFIG_DIR).
RUNNER_DIR = apps/pipe_maestro_runner

runner.login: ## Sign this machine in as a runner ([URL=http://localhost:4000], default https://pipemaestro.app; [NAME=...] [LABELS="gpu cuda"] [CAPACITY=N])
	cd $(RUNNER_DIR) && mix runner.login $(if $(URL),--url $(URL)) $(if $(NAME),--name "$(NAME)") \
		$(foreach label,$(LABELS),--label $(label)) $(if $(CAPACITY),--capacity $(CAPACITY))

runner.start: ## Connect this runner and stay online (Ctrl+C to stop) ([ROOT=~/src] code directories offered; remembered)
	cd $(RUNNER_DIR) && mix runner.start $(if $(ROOT),--root $(ROOT))

runner.doctor: ## Check this machine as a runner: claude, its sign-in, git, credentials, root, disk, platform
	cd $(RUNNER_DIR) && mix runner.doctor

runner.service: ## Run the runner in the background (ACTION=print|install|uninstall; launchd or systemd --user)
	cd $(RUNNER_DIR) && mix runner.service $(or $(ACTION),print)

runner.rel: ## Build the runner's Mix release (pipemaestro) into _build/prod/rel
	MIX_ENV=prod mix release pipe_maestro_runner --overwrite

runner.install: runner.rel ## Install pipemaestro for this user (~/.local/share and ~/.local/bin)
	rm -rf $(HOME)/.local/share/pipemaestro-runner
	mkdir -p $(HOME)/.local/share $(HOME)/.local/bin
	cp -R _build/prod/rel/pipe_maestro_runner $(HOME)/.local/share/pipemaestro-runner
	ln -sf $(HOME)/.local/share/pipemaestro-runner/bin/pipemaestro $(HOME)/.local/bin/pipemaestro
	@echo "Instalado: $(HOME)/.local/bin/pipemaestro (ponha ~/.local/bin no PATH). Comece com: pipemaestro login --url <plataforma>"

# Built in the toolchain image (docker/runner-binary), the same one a deploy
# builds them with on the server: Burrito needs an OTP its CDN publishes, plus
# Zig and xz, none of them on this machine.
runner.binary: ## Build the runner as one binary per platform into burrito_out/, in Docker ([TARGET=linux_x86_64] only one)
	$(if $(TARGET),BURRITO_TARGET=$(TARGET)) scripts/build_runner_binaries.sh burrito_out

# The runner's version of this checkout (AAAA-MM-DD.NN, or +dev.<commit> after
# one): the last commit that changed the runner, the one the control plane
# requires. Mix may print what it compiles first: the version is the last line.
runner.version: ## Print the runner's version this checkout builds (the one the control plane requires)
	@cd $(RUNNER_DIR) && mix runner.version | tail -n 1

cp.version: ## Print the control plane's version this checkout builds (HEAD's)
	@cd apps/pipe_maestro_protocol && \
		mix run --no-start -e 'IO.puts(PipeMaestroProtocol.Version.Git.current("."))' | tail -n 1

# A release is an annotated tag runner-AAAA-MM-DD.NN at a clean HEAD, named
# after today's local date and the day's next number, then the binary built
# from it. Nothing is pushed.
runner.release: ## Tag the next runner release (runner-AAAA-MM-DD.NN) and build its binary ([TARGET=...]); does not push
	@test -z "$$(git status --porcelain)" || \
		{ echo "A árvore de trabalho tem mudanças: faça commit antes de gerar uma release."; exit 1; }
	@existing=$$(git tag --points-at HEAD --list 'runner-*'); \
		test -z "$$existing" || { echo "Este commit já é a release $$existing."; exit 1; }
	@version=$$(cd $(RUNNER_DIR) && mix runner.version --next | tail -n 1); \
		echo "$$version" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}\.[0-9]{2,}$$' || \
			{ echo "Não consegui calcular a próxima versão: $$version"; exit 1; }; \
		git tag -a "runner-$$version" -m "Runner $$version" || exit 1; \
		echo "Tag runner-$$version criada."; \
		$(MAKE) runner.binary || \
			{ echo "O build falhou. A tag é só local; para apagá-la: git tag -d runner-$$version"; exit 1; }; \
		echo "Release $$version pronta em burrito_out/. Para publicar: git push origin runner-$$version"

image: ## Build the control plane's Docker image (pipemaestro), with this checkout's version
	docker build --build-arg CP_VERSION=$$($(MAKE) -s cp.version) \
		--build-arg RUNNER_VERSION=$$($(MAKE) -s runner.version) \
		-t pipemaestro .

REF ?= main

deploy: ci ## make ci, then publish REF (default main) on Sun and wait until it serves
	@$(MAKE) --no-print-directory deploy.skip-ci REF=$(REF)

deploy.skip-ci: ## Publish REF (default main, pushed to origin) on Sun and wait until it serves
	scripts/deploy_sun.sh $(REF)

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
	cd apps/pipe_maestro_web && MIX_ENV=e2e mix assets.build

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

# The director (e2e/director/) builds a realistic workspace through the UI with a
# real runner and photographs the screens the landing page shows, light and dark,
# into apps/pipe_maestro_web/priv/static/images/landing/. It starts from an empty
# e2e database: the reset wipes whatever the suite left there.
landing.shots: e2e.db.reset e2e.assets ## Regenerate the landing's screenshots (wipes the e2e database)
	@pids=$$(lsof -ti:$(E2E_PORT) 2>/dev/null); [ -z "$$pids" ] || kill -9 $$pids
	cd e2e && $(E2E_ENV) E2E_DIRECTOR=1 npx playwright test --project=director

e2e.typecheck: ## Typecheck the specs, page objects and helpers
	cd e2e && npx tsc --noEmit
