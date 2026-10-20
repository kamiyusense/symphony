.PHONY: help all setup deps build fmt fmt-check lint test coverage ci dialyzer e2e portable-test portable-coverage portable-ci portable-python os-isolation

MIX ?= mix

help:
	@echo "Targets: setup, deps, fmt, fmt-check, lint, test, coverage, dialyzer, e2e, ci, portable-test, portable-coverage, portable-ci, portable-python, os-isolation"

setup:
	$(MIX) setup

deps:
	$(MIX) deps.get

build:
	$(MIX) build

fmt:
	$(MIX) format

fmt-check:
	$(MIX) format --check-formatted

lint:
	$(MIX) lint

coverage:
	$(MIX) test --cover

test:
	$(MIX) test

dialyzer:
	$(MIX) deps.get
	$(MIX) dialyzer --format short

e2e:
	SYMPHONY_RUN_LIVE_E2E=1 $(MIX) test test/symphony_elixir/live_e2e_test.exs

ci:
	$(MAKE) setup
	$(MAKE) build
	$(MAKE) fmt-check
	$(MAKE) lint
	$(MAKE) portable-python
	$(MAKE) coverage
	$(MAKE) dialyzer

all: ci

# These gates select complementary tests; the default all/ci gate remains complete.
portable-test:
	$(MIX) test --exclude os_isolation --exclude live_e2e

portable-coverage:
	$(MIX) test --cover --exclude os_isolation --exclude live_e2e

# --keep-going allows independent analysis after a test or coverage failure.
portable-ci: setup build fmt-check lint portable-python portable-coverage dialyzer

portable-python:
	python3 -B test/local_process_diagnostics_test.py

os-isolation:
	python3 -I test/support/os_isolation_preflight.py
	$(MIX) test --only os_isolation --exclude live_e2e
