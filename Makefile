.PHONY: fuzz

LUA ?= lua
DURATION ?= 3600
INTERVAL ?= 5
WORKERS ?= 1
SEED ?= $(shell date +%s)
SORT_KEYS ?= 1

fuzz:
	@set -u; \
	tmpdir=$$(mktemp -d "$${TMPDIR:-/tmp}/lua-rapidjson-fuzz.XXXXXX"); \
	pids=""; \
	cleanup() { rm -rf "$$tmpdir"; }; \
	stop_workers() { for pid in $$pids; do kill "$$pid" 2>/dev/null || true; done; cleanup; }; \
	trap cleanup EXIT; \
	trap stop_workers INT TERM; \
	worker=1; \
	while [ "$$worker" -le "$(WORKERS)" ]; do \
		seed=$$(( $(SEED) + $$worker - 1 )); \
		( \
			DURATION="$(DURATION)" \
			INTERVAL="$(INTERVAL)" \
			WORKERS="$(WORKERS)" \
			WORKER_ID="$$worker" \
			SEED="$$seed" \
			SORT_KEYS="$(SORT_KEYS)" \
			"$(LUA)" tools/fuzz_encode.lua; \
			rc=$$?; \
			if [ "$$rc" -ne 0 ]; then \
				echo "$$rc" > "$$tmpdir/fail.$$worker"; \
			fi; \
			echo "$$rc" > "$$tmpdir/done.$$worker"; \
		) & \
		pids="$$pids $$!"; \
		worker=$$(( $$worker + 1 )); \
	done; \
	status=0; \
	while :; do \
		if ls "$$tmpdir"/fail.* >/dev/null 2>&1; then \
			status=1; \
			for pid in $$pids; do \
				kill "$$pid" 2>/dev/null || true; \
			done; \
			break; \
		fi; \
		done_count=$$(ls "$$tmpdir"/done.* 2>/dev/null | wc -l | tr -d ' '); \
		if [ "$$done_count" -ge "$(WORKERS)" ]; then \
			break; \
		fi; \
		sleep 1; \
	done; \
	for pid in $$pids; do \
		if ! wait "$$pid" 2>/dev/null; then \
			status=1; \
		fi; \
	done; \
	exit "$$status"
