# JSON Encode Fuzz Test Design

## Goal

Add a `make fuzz` entry point that runs a long-lived Lua-side fuzz test for the current JSON encode implementation. The test should stress `rapidjson.encode(value, { sort_keys = true })` with realistic Lua table shapes and verify that successful encodes produce valid, sorted, structurally correct JSON.

This is a property and stress fuzz test, not a C/C++ coverage-guided fuzzer. The highest-value input surface is Lua values, especially tables with JSON-like API response shapes.

## Command Interface

Add a root `Makefile` target:

```sh
make fuzz
make fuzz DURATION=3600 INTERVAL=5 WORKERS=1 SEED=123
```

Defaults:

- `DURATION=3600`
- `INTERVAL=5`
- `WORKERS=1`
- `SORT_KEYS=1`

`make fuzz` should use one CPU core by default. `WORKERS` is reserved for a future multi-process mode, where each worker can run the same runner with a distinct seed.

## Runner

Add `tools/fuzz_encode.lua`.

The runner will:

- Parse duration, reporting interval, worker id, worker count, seed, and sort option from command-line arguments or environment variables.
- Initialize a deterministic pseudo-random generator from the seed.
- Repeatedly generate one Lua value plus expected metadata.
- Call `rapidjson.encode(value, { sort_keys = true })`.
- Validate every successful encode.
- Print progress every reporting interval.
- Stop after the configured duration or after the first validation failure.

## Generated Cases

Each fuzz case uses a named schema inspired by real JSON-producing systems:

- LLM-style chat completion response
- GitHub-style issue or API response
- Twitter or Weibo-style feed response
- Paginated list response
- Nested metadata or configuration object

Generators should produce Lua tables with controlled depth and size. They should include strings, numbers, booleans, `rapidjson.null`, arrays, objects, empty objects, and nested collections. They should avoid unsupported Lua values such as functions, threads, full userdata, and circular tables because this fuzz target is focused on successful encode quality.

Each generated case should carry expected metadata such as:

- Schema name
- Top-level kind
- Expected object key count at selected paths
- Expected sorted key order at selected object paths
- Expected array length at selected paths
- Selected scalar path/value assertions

## Validation

For every successful encode:

- Decode the JSON with `rapidjson.decode` and ensure decoding succeeds.
- Check the decoded top-level kind.
- Check expected object field counts.
- Check expected array lengths.
- Check selected scalar path values.
- Check that keys emitted by `rapidjson.encode(..., { sort_keys = true })` appear in sorted order for tracked object paths.

The key order check should inspect the encoded JSON for tracked objects. The generated metadata should keep those tracked objects small enough that order checks can be reliable without requiring a full JSON parser beyond `rapidjson.decode`.

## Reporting

Every `INTERVAL` seconds, print a compact summary:

- Elapsed seconds
- Total cases
- Successful cases
- Encode errors
- Validation failures
- Cases per second
- Seed
- Last case id

On failure, print enough information to reproduce:

- Seed
- Case id
- Worker id
- Schema name
- Failure reason
- Generated Lua value dump
- Encoded JSON, if available

The process should exit non-zero on validation failure.

## Multi-Core Path

The first implementation runs one worker by default. The command interface should leave room for:

```sh
make fuzz WORKERS=4
```

A later implementation can start multiple Lua processes with worker-specific seeds, for example `SEED + worker_id`. Worker output can be prefixed with the worker id before adding any central aggregation.

## Test Strategy

Keep the fuzz runner separate from the normal `busted` suite because the default fuzz duration is long. Add focused unit coverage only for helper functions if the implementation grows complex enough to justify it.

Manual verification for the first version:

- Build or otherwise make `rapidjson.so` available.
- Run `make fuzz DURATION=5 INTERVAL=1 SEED=123`.
- Confirm it reports progress and exits successfully.
- Run with at least one intentionally broken assertion during development to confirm failures are reproducible and exit non-zero.
