.PHONY: fuzz

LUA ?= lua
DURATION ?= 3600
INTERVAL ?= 5
WORKERS ?= 1
SEED ?= $(shell date +%s)
SORT_KEYS ?= 1

fuzz:
	@set -eu; \
	pids=""; \
	worker=1; \
	while [ "$$worker" -le "$(WORKERS)" ]; do \
		seed=$$(( $(SEED) + $$worker - 1 )); \
		DURATION="$(DURATION)" \
		INTERVAL="$(INTERVAL)" \
		WORKERS="$(WORKERS)" \
		WORKER_ID="$$worker" \
		SEED="$$seed" \
		SORT_KEYS="$(SORT_KEYS)" \
		"$(LUA)" tools/fuzz_encode.lua & \
		pids="$$pids $$!"; \
		worker=$$(( $$worker + 1 )); \
	done; \
	status=0; \
	for pid in $$pids; do \
		if ! wait "$$pid"; then \
			status=1; \
		fi; \
	done; \
	exit "$$status"
