.PHONY: help setup deps docker.up docker.down docker.reset server iex \
	test test.cover format format.check credo dialyzer deps.check lint ci ci.quick

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
