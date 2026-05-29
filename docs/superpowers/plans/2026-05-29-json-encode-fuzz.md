# JSON Encode Fuzz Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a `make fuzz` entry point that runs a long-lived Lua-side fuzz test for `rapidjson.encode(value, { sort_keys = true })`.

**Architecture:** Add a reusable Lua module for deterministic generation, metadata, validation, dumping, and summary formatting. Add a thin executable runner that wires that module to `rapidjson`, then expose it through a root `Makefile` target with configurable duration, interval, workers, seed, and sort behavior.

**Tech Stack:** Lua 5.1-compatible code, LuaJIT/Lua, Busted specs, existing `rapidjson` Lua module, POSIX `make` and shell.

---

## File Structure

- Create `tools/fuzz_encode_lib.lua`: deterministic RNG, config parsing, real-world-shaped case generation, validation helpers, value dumping, and summary formatting. This is importable from Busted specs.
- Create `tools/fuzz_encode.lua`: command-line runner that requires `rapidjson` and `tools.fuzz_encode_lib`, executes the timed loop, prints progress, and exits non-zero on validation failure.
- Create `spec/fuzz_encode_lib_spec.lua`: fast Busted coverage for config parsing, deterministic generation, expected metadata, validation failures, and summary formatting.
- Create `Makefile`: `make fuzz` target with `DURATION`, `INTERVAL`, `WORKERS`, `SEED`, `SORT_KEYS`, and `LUA` variables.

No C++ production code changes are needed.

---

## Execution Preflight

Before running specs that require `rapidjson`, make the module available from the worktree root.

- [ ] **Step 1: Check whether `rapidjson` already loads**

Run:

```bash
luajit -e 'require("rapidjson"); print("rapidjson ok")'
```

Expected when already built: `rapidjson ok`.

- [ ] **Step 2: Build `rapidjson.so` for local LuaJIT if the check fails**

Run:

```bash
c++ -std=c++11 -g -Wall -fPIC \
  -I/opt/homebrew/include/luajit-2.1 \
  -Irapidjson/include \
  -bundle -undefined dynamic_lookup -all_load \
  src/Document.cpp src/Schema.cpp src/rapidjson.cpp src/values.cpp \
  -o rapidjson.so
```

Expected: compile succeeds. Warnings from `src/luax.hpp` about integer-to-double conversion are pre-existing on this checkout.

---

### Task 1: Testable Fuzz Library Skeleton

**Files:**
- Create: `tools/fuzz_encode_lib.lua`
- Create: `spec/fuzz_encode_lib_spec.lua`

- [ ] **Step 1: Write the failing tests for config parsing, deterministic RNG, and summary formatting**

Create `spec/fuzz_encode_lib_spec.lua` with:

```lua
require 'busted.runner'()

describe('tools.fuzz_encode_lib', function()
  local fuzz = require('tools.fuzz_encode_lib')

  describe('parse_config', function()
    it('uses production defaults', function()
      local cfg = fuzz.parse_config({})

      assert.are.equal(3600, cfg.duration)
      assert.are.equal(5, cfg.interval)
      assert.are.equal(1, cfg.workers)
      assert.are.equal(1, cfg.worker_id)
      assert.are.equal(true, cfg.sort_keys)
      assert.are.equal('number', type(cfg.seed))
    end)

    it('accepts numeric and boolean overrides', function()
      local cfg = fuzz.parse_config({
        DURATION = '12',
        INTERVAL = '3',
        WORKERS = '2',
        WORKER_ID = '2',
        SEED = '99',
        SORT_KEYS = '0',
      })

      assert.are.equal(12, cfg.duration)
      assert.are.equal(3, cfg.interval)
      assert.are.equal(2, cfg.workers)
      assert.are.equal(2, cfg.worker_id)
      assert.are.equal(99, cfg.seed)
      assert.are.equal(false, cfg.sort_keys)
    end)
  end)

  describe('new_rng', function()
    it('is deterministic for the same seed', function()
      local a = fuzz.new_rng(123)
      local b = fuzz.new_rng(123)

      assert.are.equal(a:int(1, 1000000), b:int(1, 1000000))
      assert.are.equal(a:int(1, 1000000), b:int(1, 1000000))
      assert.are.equal(a:bool(), b:bool())
    end)
  end)

  describe('format_summary', function()
    it('formats the progress counters', function()
      local line = fuzz.format_summary({
        elapsed = 5,
        total = 100,
        encoded = 99,
        encode_errors = 1,
        validation_failures = 0,
        rate = 20,
        seed = 123,
        last_case_id = 100,
        worker_id = 1,
      })

      assert.matches('worker=1', line, 1, true)
      assert.matches('elapsed=5s', line, 1, true)
      assert.matches('total=100', line, 1, true)
      assert.matches('encoded=99', line, 1, true)
      assert.matches('encode_errors=1', line, 1, true)
      assert.matches('validation_failures=0', line, 1, true)
      assert.matches('rate=20.00/s', line, 1, true)
      assert.matches('seed=123', line, 1, true)
      assert.matches('last_case=100', line, 1, true)
    end)
  end)
end)
```

- [ ] **Step 2: Run the focused spec and verify it fails because the module does not exist**

Run:

```bash
/Users/yuanshengwang/.luarocks/bin/busted spec/fuzz_encode_lib_spec.lua
```

Expected: FAIL or ERROR with `module 'tools.fuzz_encode_lib' not found`.

- [ ] **Step 3: Implement the minimal library skeleton**

Create `tools/fuzz_encode_lib.lua` with:

```lua
local M = {}

local DEFAULTS = {
  duration = 3600,
  interval = 5,
  workers = 1,
  worker_id = 1,
  sort_keys = true,
}

local function tonumber_or(value, default)
  local parsed = tonumber(value)
  if parsed == nil then
    return default
  end
  return parsed
end

local function normalize_seed(value)
  local parsed = tonumber(value)
  if parsed == nil then
    parsed = os.time()
  end
  parsed = math.floor(parsed)
  parsed = parsed % 2147483647
  if parsed <= 0 then
    parsed = 1
  end
  return parsed
end

function M.parse_config(env)
  env = env or {}
  return {
    duration = tonumber_or(env.DURATION, DEFAULTS.duration),
    interval = tonumber_or(env.INTERVAL, DEFAULTS.interval),
    workers = tonumber_or(env.WORKERS, DEFAULTS.workers),
    worker_id = tonumber_or(env.WORKER_ID, DEFAULTS.worker_id),
    seed = normalize_seed(env.SEED),
    sort_keys = env.SORT_KEYS ~= '0',
  }
end

function M.new_rng(seed)
  local state = normalize_seed(seed)
  local rng = {}

  function rng:next()
    local hi = math.floor(state / 127773)
    local lo = state % 127773
    local test = 16807 * lo - 2836 * hi
    if test <= 0 then
      test = test + 2147483647
    end
    state = test
    return state / 2147483647
  end

  function rng:int(min, max)
    return min + math.floor(self:next() * (max - min + 1))
  end

  function rng:bool()
    return self:int(0, 1) == 1
  end

  function rng:choice(values)
    return values[self:int(1, #values)]
  end

  return rng
end

function M.format_summary(stats)
  return string.format(
    'worker=%d elapsed=%ds total=%d encoded=%d encode_errors=%d validation_failures=%d rate=%.2f/s seed=%d last_case=%d',
    stats.worker_id,
    stats.elapsed,
    stats.total,
    stats.encoded,
    stats.encode_errors,
    stats.validation_failures,
    stats.rate,
    stats.seed,
    stats.last_case_id
  )
end

return M
```

- [ ] **Step 4: Run the focused spec and verify it passes**

Run:

```bash
/Users/yuanshengwang/.luarocks/bin/busted spec/fuzz_encode_lib_spec.lua
```

Expected: PASS with all `tools.fuzz_encode_lib` examples successful.

- [ ] **Step 5: Commit the skeleton**

Run:

```bash
git add tools/fuzz_encode_lib.lua spec/fuzz_encode_lib_spec.lua
git commit -m "test: add fuzz encode library skeleton"
```

---

### Task 2: Real-World Case Generators and Metadata

**Files:**
- Modify: `tools/fuzz_encode_lib.lua`
- Modify: `spec/fuzz_encode_lib_spec.lua`

- [ ] **Step 1: Add failing tests for generated schemas and expected metadata**

Append these tests inside the top-level `describe('tools.fuzz_encode_lib', function()` block in `spec/fuzz_encode_lib_spec.lua`:

```lua
  describe('generate_case', function()
    it('generates deterministic real-world schema cases with metadata', function()
      local a = fuzz.generate_case(fuzz.new_rng(321), 1, { null = {} })
      local b = fuzz.generate_case(fuzz.new_rng(321), 1, { null = {} })

      assert.are.same(a.value, b.value)
      assert.are.same(a.expected, b.expected)
      assert.are.equal('number', type(a.id))
      assert.are.equal('string', type(a.schema))
      assert.are.equal('object', a.expected.top_level_kind)
      assert.is_true(#a.expected.objects >= 1)
      assert.is_true(#a.expected.arrays >= 1)
      assert.is_true(#a.expected.scalars >= 1)
    end)

    it('cycles through the five supported schema families', function()
      local rng = fuzz.new_rng(1)
      local seen = {}

      for case_id = 1, 10 do
        local case = fuzz.generate_case(rng, case_id, { null = {} })
        seen[case.schema] = true
      end

      assert.is_true(seen.llm_response)
      assert.is_true(seen.github_issue)
      assert.is_true(seen.social_feed)
      assert.is_true(seen.paginated_list)
      assert.is_true(seen.metadata_config)
    end)
  end)
```

- [ ] **Step 2: Run the focused spec and verify it fails because `generate_case` is missing**

Run:

```bash
/Users/yuanshengwang/.luarocks/bin/busted spec/fuzz_encode_lib_spec.lua
```

Expected: FAIL with `attempt to call field 'generate_case'`.

- [ ] **Step 3: Implement generator helpers and schema generators**

Add these helpers to `tools/fuzz_encode_lib.lua` before `return M`:

```lua
local SCHEMAS = {
  'llm_response',
  'github_issue',
  'social_feed',
  'paginated_list',
  'metadata_config',
}

local WORDS = {
  'alpha', 'bravo', 'charlie', 'delta', 'echo', 'foxtrot',
  'json', 'encode', 'rapid', 'lua', 'api', '模型', '微博',
}

local function sentence(rng, min_words, max_words)
  local parts = {}
  for _ = 1, rng:int(min_words, max_words) do
    parts[#parts + 1] = rng:choice(WORDS)
  end
  return table.concat(parts, ' ')
end

local function string_keys(tbl)
  local keys = {}
  for key, _ in pairs(tbl) do
    if type(key) == 'string' then
      keys[#keys + 1] = key
    end
  end
  table.sort(keys)
  return keys
end

local function path_value(root, path)
  local current = root
  for i = 1, #path do
    current = current[path[i]]
  end
  return current
end

local function track_object(expected, label, value, path, check_order)
  expected.objects[#expected.objects + 1] = {
    label = label,
    path = path,
    count = #string_keys(value),
    keys = string_keys(value),
    check_order = check_order == true,
  }
end

local function track_array(expected, label, value, path)
  expected.arrays[#expected.arrays + 1] = {
    label = label,
    path = path,
    length = #value,
  }
end

local function track_scalar(expected, label, value, path)
  expected.scalars[#expected.scalars + 1] = {
    label = label,
    path = path,
    value = path_value(value, path),
  }
end

local function base_expected(schema)
  return {
    schema = schema,
    top_level_kind = 'object',
    objects = {},
    arrays = {},
    scalars = {},
  }
end

local function generate_llm_response(rng, case_id, rapidjson)
  local value = {
    id = 'chatcmpl-' .. case_id,
    object = 'chat.completion',
    created = 1700000000 + case_id,
    model = rng:choice({ 'gpt-4.1', 'gpt-4o-mini', 'reasoner-small' }),
    choices = {
      {
        index = 0,
        finish_reason = rng:choice({ 'stop', 'length', 'tool_calls' }),
        message = {
          role = 'assistant',
          content = sentence(rng, 4, 10),
        },
      },
    },
    usage = {
      prompt_tokens = rng:int(1, 2000),
      completion_tokens = rng:int(1, 2000),
      total_tokens = rng:int(2001, 5000),
    },
    metadata = {
      request_id = 'req_' .. rng:int(1000, 9999),
      cached = rng:bool(),
      trace = rapidjson.null,
    },
  }
  local expected = base_expected('llm_response')
  track_object(expected, 'root', value, {}, true)
  track_object(expected, 'usage', value.usage, { 'usage' }, true)
  track_array(expected, 'choices', value.choices, { 'choices' })
  track_scalar(expected, 'model', value, { 'model' })
  track_scalar(expected, 'message_role', value, { 'choices', 1, 'message', 'role' })
  return value, expected
end

local function generate_github_issue(rng, case_id, rapidjson)
  local labels = {}
  for i = 1, rng:int(1, 4) do
    labels[i] = {
      id = case_id * 100 + i,
      name = rng:choice({ 'bug', 'feature', 'fuzz', 'help wanted' }),
      color = rng:choice({ 'ff0000', '00ff00', '0052cc' }),
    }
  end
  local value = {
    id = case_id,
    number = rng:int(1, 10000),
    state = rng:choice({ 'open', 'closed' }),
    title = sentence(rng, 3, 8),
    body = sentence(rng, 8, 18),
    user = {
      login = 'user' .. rng:int(1, 999),
      id = rng:int(1, 100000),
      site_admin = false,
    },
    labels = labels,
    milestone = rapidjson.null,
    reactions = {
      ['+1'] = rng:int(0, 100),
      ['-1'] = rng:int(0, 10),
      confused = rng:int(0, 5),
      heart = rng:int(0, 50),
    },
  }
  local expected = base_expected('github_issue')
  track_object(expected, 'root', value, {}, true)
  track_object(expected, 'user', value.user, { 'user' }, true)
  track_object(expected, 'reactions', value.reactions, { 'reactions' }, true)
  track_array(expected, 'labels', value.labels, { 'labels' })
  track_scalar(expected, 'state', value, { 'state' })
  return value, expected
end

local function generate_social_feed(rng, case_id, rapidjson)
  local posts = {}
  for i = 1, rng:int(2, 5) do
    posts[i] = {
      id = 'post_' .. case_id .. '_' .. i,
      text = sentence(rng, 5, 15),
      reposts = rng:int(0, 1000),
      likes = rng:int(0, 10000),
      verified = rng:bool(),
      reply_to = rapidjson.null,
    }
  end
  local value = {
    platform = rng:choice({ 'twitter', 'weibo' }),
    cursor = 'cursor_' .. rng:int(1000, 9999),
    has_more = rng:bool(),
    posts = posts,
    viewer = {
      locale = rng:choice({ 'en-US', 'zh-CN', 'ja-JP' }),
      safe_mode = rng:bool(),
    },
  }
  local expected = base_expected('social_feed')
  track_object(expected, 'root', value, {}, true)
  track_object(expected, 'viewer', value.viewer, { 'viewer' }, true)
  track_array(expected, 'posts', value.posts, { 'posts' })
  track_scalar(expected, 'platform', value, { 'platform' })
  return value, expected
end

local function generate_paginated_list(rng, case_id, rapidjson)
  local items = {}
  for i = 1, rng:int(1, 6) do
    items[i] = {
      id = case_id * 10 + i,
      name = 'item_' .. rng:int(100, 999),
      enabled = rng:bool(),
      score = rng:int(0, 10000) / 100,
      extra = rapidjson.null,
    }
  end
  local value = {
    page = rng:int(1, 50),
    per_page = #items,
    total = rng:int(#items, #items + 500),
    items = items,
    links = {
      next = '/api/items?page=' .. rng:int(2, 99),
      prev = rapidjson.null,
    },
  }
  local expected = base_expected('paginated_list')
  track_object(expected, 'root', value, {}, true)
  track_object(expected, 'links', value.links, { 'links' }, true)
  track_array(expected, 'items', value.items, { 'items' })
  track_scalar(expected, 'per_page', value, { 'per_page' })
  return value, expected
end

local function generate_metadata_config(rng, case_id, rapidjson)
  local value = {
    version = 'v' .. rng:int(1, 9) .. '.' .. rng:int(0, 9),
    rollout = {
      percent = rng:int(0, 100),
      region = rng:choice({ 'us', 'sg', 'eu', 'cn' }),
      enabled = rng:bool(),
    },
    features = {
      encode_fuzz = true,
      sorted_json = true,
      experimental = rng:bool(),
    },
    owners = {
      'team-api',
      'team-runtime',
    },
    annotations = {
      case_id = case_id,
      note = sentence(rng, 2, 6),
      empty = rapidjson.null,
    },
  }
  local expected = base_expected('metadata_config')
  track_object(expected, 'root', value, {}, true)
  track_object(expected, 'rollout', value.rollout, { 'rollout' }, true)
  track_object(expected, 'features', value.features, { 'features' }, true)
  track_array(expected, 'owners', value.owners, { 'owners' })
  track_scalar(expected, 'version', value, { 'version' })
  return value, expected
end

local GENERATORS = {
  llm_response = generate_llm_response,
  github_issue = generate_github_issue,
  social_feed = generate_social_feed,
  paginated_list = generate_paginated_list,
  metadata_config = generate_metadata_config,
}

function M.generate_case(rng, case_id, rapidjson)
  local schema = SCHEMAS[((case_id - 1) % #SCHEMAS) + 1]
  local value, expected = GENERATORS[schema](rng, case_id, rapidjson)
  return {
    id = case_id,
    schema = schema,
    value = value,
    expected = expected,
  }
end
```

- [ ] **Step 4: Run the focused spec and verify it passes**

Run:

```bash
/Users/yuanshengwang/.luarocks/bin/busted spec/fuzz_encode_lib_spec.lua
```

Expected: PASS.

- [ ] **Step 5: Commit the generators**

Run:

```bash
git add tools/fuzz_encode_lib.lua spec/fuzz_encode_lib_spec.lua
git commit -m "feat: generate json encode fuzz cases"
```

---

### Task 3: Encode Result Validation and Failure Diagnostics

**Files:**
- Modify: `tools/fuzz_encode_lib.lua`
- Modify: `spec/fuzz_encode_lib_spec.lua`

- [ ] **Step 1: Add failing tests for validation and diagnostics**

Append these tests inside the top-level `describe('tools.fuzz_encode_lib', function()` block:

```lua
  describe('validate_encoded_case', function()
    local rapidjson = require('rapidjson')

    it('accepts a generated case encoded with sorted keys', function()
      local case = fuzz.generate_case(fuzz.new_rng(77), 1, rapidjson)
      local json = rapidjson.encode(case.value, { sort_keys = true })

      local ok, err = fuzz.validate_encoded_case(rapidjson, case, json)

      assert.is_true(ok)
      assert.is_nil(err)
    end)

    it('rejects unsorted encoded object keys for tracked objects', function()
      local case = {
        id = 1,
        schema = 'manual',
        value = { b = 1, a = 2 },
        expected = {
          top_level_kind = 'object',
          objects = {
            {
              label = 'root',
              path = {},
              count = 2,
              keys = { 'a', 'b' },
              check_order = true,
            },
          },
          arrays = {},
          scalars = {},
        },
      }

      local ok, err = fuzz.validate_encoded_case(rapidjson, case, '{"b":1,"a":2}')

      assert.is_false(ok)
      assert.matches('key order', err, 1, true)
    end)

    it('formats reproducible failure reports', function()
      local report = fuzz.format_failure({
        seed = 123,
        worker_id = 1,
        case = {
          id = 7,
          schema = 'manual',
          value = { b = 1, a = 2 },
        },
        json = '{"b":1,"a":2}',
        reason = 'root key order mismatch',
      })

      assert.matches('seed=123', report, 1, true)
      assert.matches('worker=1', report, 1, true)
      assert.matches('case=7', report, 1, true)
      assert.matches('schema=manual', report, 1, true)
      assert.matches('root key order mismatch', report, 1, true)
      assert.matches('json={"b":1,"a":2}', report, 1, true)
      assert.matches('value={', report, 1, true)
    end)
  end)
```

- [ ] **Step 2: Run the focused spec and verify it fails because validation is missing**

Run:

```bash
/Users/yuanshengwang/.luarocks/bin/busted spec/fuzz_encode_lib_spec.lua
```

Expected: FAIL with `attempt to call field 'validate_encoded_case'`.

- [ ] **Step 3: Implement validation, path lookup, and value dump helpers**

Add these functions to `tools/fuzz_encode_lib.lua` before `return M`:

```lua
local function kind(value)
  if type(value) ~= 'table' then
    return type(value)
  end
  if #value > 0 then
    return 'array'
  end
  return 'object'
end

local function value_at_path(root, path)
  local current = root
  for i = 1, #path do
    if type(current) ~= 'table' then
      return nil
    end
    current = current[path[i]]
  end
  return current
end

local function deep_equal(a, b)
  if type(a) ~= type(b) then
    return false
  end
  if type(a) ~= 'table' then
    return a == b
  end
  for key, value in pairs(a) do
    if not deep_equal(value, b[key]) then
      return false
    end
  end
  for key, _ in pairs(b) do
    if a[key] == nil then
      return false
    end
  end
  return true
end

local function key_token(key)
  return '"' .. key .. '":'
end

local function keys_are_sorted_in_json(json, keys)
  local previous = 0
  for _, key in ipairs(keys) do
    local pos = string.find(json, key_token(key), previous + 1, true)
    if pos == nil then
      return false, 'missing key "' .. key .. '"'
    end
    if pos < previous then
      return false, 'key "' .. key .. '" appeared out of order'
    end
    previous = pos
  end
  return true
end

local function dump_value(value, depth, seen)
  depth = depth or 0
  seen = seen or {}
  if type(value) == 'string' then
    return string.format('%q', value)
  end
  if type(value) ~= 'table' then
    return tostring(value)
  end
  if seen[value] then
    return '<cycle>'
  end
  if depth >= 4 then
    return '{...}'
  end
  seen[value] = true
  local parts = {}
  local keys = {}
  for key, _ in pairs(value) do
    keys[#keys + 1] = key
  end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  for _, key in ipairs(keys) do
    parts[#parts + 1] = '[' .. dump_value(key, depth + 1, seen) .. ']=' .. dump_value(value[key], depth + 1, seen)
  end
  seen[value] = nil
  return '{' .. table.concat(parts, ',') .. '}'
end

function M.validate_encoded_case(rapidjson, case, json)
  local decoded, decode_err = rapidjson.decode(json)
  if decoded == nil then
    return false, 'decode failed: ' .. tostring(decode_err)
  end

  if kind(decoded) ~= case.expected.top_level_kind then
    return false, 'top-level kind mismatch: expected ' .. case.expected.top_level_kind .. ', got ' .. kind(decoded)
  end

  for _, object in ipairs(case.expected.objects) do
    local value = value_at_path(decoded, object.path)
    if kind(value) ~= 'object' then
      return false, object.label .. ' kind mismatch'
    end
    if #string_keys(value) ~= object.count then
      return false, object.label .. ' field count mismatch'
    end
    if object.check_order then
      local ok, reason = keys_are_sorted_in_json(json, object.keys)
      if not ok then
        return false, object.label .. ' key order mismatch: ' .. reason
      end
    end
  end

  for _, array in ipairs(case.expected.arrays) do
    local value = value_at_path(decoded, array.path)
    if kind(value) ~= 'array' then
      return false, array.label .. ' kind mismatch'
    end
    if #value ~= array.length then
      return false, array.label .. ' length mismatch'
    end
  end

  for _, scalar in ipairs(case.expected.scalars) do
    local value = value_at_path(decoded, scalar.path)
    if not deep_equal(value, scalar.value) then
      return false, scalar.label .. ' scalar mismatch'
    end
  end

  return true
end

function M.dump_value(value)
  return dump_value(value)
end

function M.format_failure(details)
  local lines = {
    'FUZZ FAILURE',
    'seed=' .. tostring(details.seed),
    'worker=' .. tostring(details.worker_id),
    'case=' .. tostring(details.case.id),
    'schema=' .. tostring(details.case.schema),
    'reason=' .. tostring(details.reason),
    'value=' .. M.dump_value(details.case.value),
  }
  if details.json then
    lines[#lines + 1] = 'json=' .. details.json
  end
  return table.concat(lines, '\n')
end
```

- [ ] **Step 4: Run the focused spec and verify it passes**

Run:

```bash
/Users/yuanshengwang/.luarocks/bin/busted spec/fuzz_encode_lib_spec.lua
```

Expected: PASS.

- [ ] **Step 5: Run the existing encode spec to catch regressions**

Run:

```bash
/Users/yuanshengwang/.luarocks/bin/busted spec/json_encode_spec.lua
```

Expected: PASS.

- [ ] **Step 6: Commit validation**

Run:

```bash
git add tools/fuzz_encode_lib.lua spec/fuzz_encode_lib_spec.lua
git commit -m "feat: validate json encode fuzz output"
```

---

### Task 4: Runner and `make fuzz` Entry Point

**Files:**
- Create: `tools/fuzz_encode.lua`
- Create: `Makefile`
- Modify: `spec/fuzz_encode_lib_spec.lua`

- [ ] **Step 1: Add failing tests for runner argument environment conversion**

Append this test inside the top-level `describe('tools.fuzz_encode_lib', function()` block:

```lua
  describe('env_from_args', function()
    it('turns KEY=VALUE args into config environment entries', function()
      local env = fuzz.env_from_args({
        'DURATION=2',
        'INTERVAL=1',
        'SEED=123',
        'WORKERS=1',
      })

      assert.are.equal('2', env.DURATION)
      assert.are.equal('1', env.INTERVAL)
      assert.are.equal('123', env.SEED)
      assert.are.equal('1', env.WORKERS)
    end)
  end)
```

- [ ] **Step 2: Run the focused spec and verify it fails because `env_from_args` is missing**

Run:

```bash
/Users/yuanshengwang/.luarocks/bin/busted spec/fuzz_encode_lib_spec.lua
```

Expected: FAIL with `attempt to call field 'env_from_args'`.

- [ ] **Step 3: Implement `env_from_args`**

Add this function to `tools/fuzz_encode_lib.lua` before `return M`:

```lua
function M.env_from_args(args)
  local env = {}
  for _, arg in ipairs(args or {}) do
    local key, value = string.match(arg, '^([%w_]+)=(.*)$')
    if key then
      env[key] = value
    end
  end
  return env
end
```

- [ ] **Step 4: Run the focused spec and verify it passes**

Run:

```bash
/Users/yuanshengwang/.luarocks/bin/busted spec/fuzz_encode_lib_spec.lua
```

Expected: PASS.

- [ ] **Step 5: Implement the fuzz runner**

Create `tools/fuzz_encode.lua` with:

```lua
local rapidjson = require('rapidjson')
local fuzz = require('tools.fuzz_encode_lib')

local env = fuzz.env_from_args(arg)
for _, key in ipairs({ 'DURATION', 'INTERVAL', 'WORKERS', 'WORKER_ID', 'SEED', 'SORT_KEYS' }) do
  if env[key] == nil then
    env[key] = os.getenv(key)
  end
end

local cfg = fuzz.parse_config(env)
local rng = fuzz.new_rng(cfg.seed)
local started = os.time()
local next_report = started + cfg.interval
local deadline = started + cfg.duration
local stats = {
  worker_id = cfg.worker_id,
  elapsed = 0,
  total = 0,
  encoded = 0,
  encode_errors = 0,
  validation_failures = 0,
  rate = 0,
  seed = cfg.seed,
  last_case_id = 0,
}

local function update_stats(now)
  stats.elapsed = now - started
  if stats.elapsed <= 0 then
    stats.rate = stats.total
  else
    stats.rate = stats.total / stats.elapsed
  end
end

while os.time() < deadline do
  local case_id = stats.total + 1
  local case = fuzz.generate_case(rng, case_id, rapidjson)
  local ok, json_or_err = pcall(rapidjson.encode, case.value, { sort_keys = cfg.sort_keys })

  stats.total = stats.total + 1
  stats.last_case_id = case_id

  if ok then
    stats.encoded = stats.encoded + 1
    local valid, reason = fuzz.validate_encoded_case(rapidjson, case, json_or_err)
    if not valid then
      stats.validation_failures = stats.validation_failures + 1
      update_stats(os.time())
      io.stderr:write(fuzz.format_failure({
        seed = cfg.seed,
        worker_id = cfg.worker_id,
        case = case,
        json = json_or_err,
        reason = reason,
      }), '\n')
      os.exit(1)
    end
  else
    stats.encode_errors = stats.encode_errors + 1
  end

  local now = os.time()
  if now >= next_report then
    update_stats(now)
    print(fuzz.format_summary(stats))
    next_report = now + cfg.interval
  end
end

update_stats(os.time())
print(fuzz.format_summary(stats))
```

- [ ] **Step 6: Implement `make fuzz`**

Create `Makefile` with:

```make
.PHONY: fuzz

LUA ?= lua
DURATION ?= 3600
INTERVAL ?= 5
WORKERS ?= 1
SEED ?= $(shell date +%s)
SORT_KEYS ?= 1

fuzz:
	@if [ "$(WORKERS)" = "1" ]; then \
		DURATION="$(DURATION)" \
		INTERVAL="$(INTERVAL)" \
		WORKERS="$(WORKERS)" \
		WORKER_ID="1" \
		SEED="$(SEED)" \
		SORT_KEYS="$(SORT_KEYS)" \
		$(LUA) tools/fuzz_encode.lua; \
	else \
		i=1; \
		pids=""; \
		while [ $$i -le "$(WORKERS)" ]; do \
			worker_seed=$$(expr "$(SEED)" + $$i - 1); \
			DURATION="$(DURATION)" \
			INTERVAL="$(INTERVAL)" \
			WORKERS="$(WORKERS)" \
			WORKER_ID="$$i" \
			SEED="$$worker_seed" \
			SORT_KEYS="$(SORT_KEYS)" \
			$(LUA) tools/fuzz_encode.lua & \
			pids="$$pids $$!"; \
			i=$$(expr $$i + 1); \
		done; \
		status=0; \
		for pid in $$pids; do \
			wait $$pid || status=$$?; \
		done; \
		exit $$status; \
	fi
```

- [ ] **Step 7: Run the focused specs**

Run:

```bash
/Users/yuanshengwang/.luarocks/bin/busted spec/fuzz_encode_lib_spec.lua
```

Expected: PASS.

- [ ] **Step 8: Run a short single-worker fuzz smoke test**

Use LuaJIT if the local `rapidjson.so` was built for LuaJIT:

```bash
make fuzz LUA=luajit DURATION=2 INTERVAL=1 WORKERS=1 SEED=123
```

Expected: at least one progress line containing `worker=1`, `validation_failures=0`, `seed=123`, and exit code 0.

- [ ] **Step 9: Run a short multi-worker fuzz smoke test**

Run:

```bash
make fuzz LUA=luajit DURATION=2 INTERVAL=1 WORKERS=2 SEED=123
```

Expected: progress lines from `worker=1` and `worker=2`, both with `validation_failures=0`, and exit code 0.

- [ ] **Step 10: Run the complete existing test suite**

Run:

```bash
/Users/yuanshengwang/.luarocks/bin/busted
```

Expected: all existing specs pass.

- [ ] **Step 11: Commit runner and Makefile**

Run:

```bash
git add Makefile tools/fuzz_encode.lua tools/fuzz_encode_lib.lua spec/fuzz_encode_lib_spec.lua
git commit -m "feat: add json encode fuzz runner"
```

---

## Final Verification

- [ ] Run:

```bash
git status --short
```

Expected: no uncommitted changes except intentional local build outputs ignored by Git.

- [ ] Run:

```bash
make fuzz LUA=luajit DURATION=5 INTERVAL=1 WORKERS=1 SEED=123
```

Expected: repeated summaries for 5 seconds, `validation_failures=0`, exit code 0.

- [ ] Run:

```bash
/Users/yuanshengwang/.luarocks/bin/busted
```

Expected: complete suite passes.

---

## Self-Review

- Spec coverage: `make fuzz`, default single worker, configurable duration/interval/workers/seed/sort, realistic generators, encode with sort, validation, five-second summaries, failure diagnostics, and multi-worker path are all covered.
- Red-flag scan: no vague implementation tasks remain; every code-changing step includes concrete code.
- Type consistency: functions referenced by tests are defined in earlier or same-task implementation steps: `parse_config`, `new_rng`, `format_summary`, `generate_case`, `validate_encoded_case`, `format_failure`, and `env_from_args`.
