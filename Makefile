.PHONY: help build format format-check clean seed-load-test-data load-test load-test-cache-stress smoke-test

help: ## Show this help message
	@echo Available commands:
	@echo   build                   - Compile the simulations (no run)
	@echo   format                  - Auto-format code with Spotless
	@echo   format-check            - Check code formatting without modifying files
	@echo   clean                   - Remove build artifacts
	@echo   seed-load-test-data     - Seed sample products via real API calls (idempotent-ish)
	@echo   load-test               - Run the full user-journey Gatling simulation
	@echo   load-test-cache-stress  - Run the read-heavy catalog stress Gatling simulation
	@echo   smoke-test              - Run the full end-to-end flow smoke test (not a load test)

build: ## Compile the simulations (no run)
	mvn --batch-mode --no-transfer-progress gatling:compile

format: ## Auto-format code with Spotless
	mvn --batch-mode --no-transfer-progress spotless:apply

format-check: ## Check code formatting without modifying files
	mvn --batch-mode --no-transfer-progress spotless:check

clean: ## Remove build artifacts
	mvn --batch-mode --no-transfer-progress clean

seed-load-test-data: ## Seed sample products via real API calls (idempotent-ish)
	./scripts/seed-products.sh

load-test: ## Run the full user-journey Gatling simulation (needs seeded data first)
	mvn --batch-mode --no-transfer-progress gatling:test -Dgatling.simulationClass=pl.dybcio.ordered.gatling.UserJourneySimulation

load-test-cache-stress: ## Run the read-heavy catalog stress Gatling simulation
	mvn --batch-mode --no-transfer-progress gatling:test -Dgatling.simulationClass=pl.dybcio.ordered.gatling.ProductCatalogStressSimulation

smoke-test: ## Run the full end-to-end flow smoke test (not a load test - correctness, not throughput)
	./scripts/smoke-test-full-flow.sh
