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
    sort_keys = env.SORT_KEYS ~= '0' and env.SORT_KEYS ~= 0,
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

local SCHEMA_FAMILIES = {
  'llm_response',
  'github_issue',
  'social_feed',
  'paginated_list',
  'metadata_config',
}

local CASE_KINDS = {
  'schema_guided',
  'recursive_random',
  'recursive_random',
}

local EMPTY_ARRAY_MT = { __jsontype = 'array' }

local KEY_PARTS = {
  'alpha',
  'body',
  'cache',
  'delta',
  'edge',
  'flags',
  'group',
  'hint',
  'index',
  'job',
  'kind',
  'limit',
  'meta',
  'node',
  'option',
  'payload',
  'query',
  'result',
  'state',
  'token',
}

local STRING_PARTS = {
  'adapter',
  'batch',
  'cursor',
  'draft',
  'event',
  'filter',
  'gateway',
  'header',
  'intent',
  'journal',
  'kernel',
  'ledger',
  'message',
  'notice',
  'offset',
  'profile',
  'record',
  'signal',
  'thread',
  'update',
}

local function json_null(rapidjson)
  if rapidjson and type(rapidjson.encode) == 'function' and rapidjson.null ~= nil then
    local ok, encoded = pcall(rapidjson.encode, rapidjson.null)
    if ok and encoded == 'null' then
      return rapidjson.null
    end
  end

  error('rapidjson.null is required', 0)
end

local function empty_json_array()
  return setmetatable({}, EMPTY_ARRAY_MT)
end

local function random_integer(rng)
  return rng:int(-1000000, 1000000)
end

local function random_float(rng)
  local whole = rng:int(1, 100000)
  local fraction = rng:int(1, 999) / 1000
  local sign = rng:bool() and 1 or -1
  return sign * (whole + fraction)
end

local function random_string(rng)
  local count = rng:int(1, 4)
  local parts = {}

  for i = 1, count do
    parts[#parts + 1] = rng:choice(STRING_PARTS)
  end

  return table.concat(parts, '-') .. '-' .. tostring(rng:int(1, 9999))
end

local function random_key(rng)
  return rng:choice(KEY_PARTS) .. '_' .. tostring(rng:int(1, 999))
end

local function random_scalar(rng, rapidjson)
  local scalar_kind = rng:int(1, 6)

  if scalar_kind == 1 then
    return random_string(rng)
  elseif scalar_kind == 2 then
    return random_integer(rng)
  elseif scalar_kind == 3 then
    return random_float(rng)
  elseif scalar_kind == 4 then
    return rng:bool()
  elseif scalar_kind == 5 then
    return json_null(rapidjson)
  end

  return ''
end

local generate_random_value

local function unique_random_key(rng, object)
  local key = random_key(rng)

  while object[key] ~= nil do
    key = random_key(rng)
  end

  return key
end

local function generate_random_object(rng, rapidjson, depth, max_depth)
  local object = {}
  local width = rng:int(1, 5)
  local forced_nested_index

  if depth < max_depth - 1 then
    forced_nested_index = rng:int(1, width)
  end

  for i = 1, width do
    local key = unique_random_key(rng, object)

    if i == forced_nested_index then
      object[key] = generate_random_value(rng, rapidjson, depth + 1, max_depth)
    elseif depth >= max_depth - 1 or rng:int(1, 100) <= 45 then
      object[key] = random_scalar(rng, rapidjson)
    else
      object[key] = generate_random_value(rng, rapidjson, depth + 1, max_depth)
    end
  end

  return object
end

local function generate_random_array(rng, rapidjson, depth, max_depth)
  local array = {}
  local length = rng:int(1, 5)
  local forced_nested_index

  if depth < max_depth - 1 then
    forced_nested_index = rng:int(1, length)
  end

  for i = 1, length do
    if i == forced_nested_index then
      array[i] = generate_random_value(rng, rapidjson, depth + 1, max_depth)
    elseif depth >= max_depth - 1 or rng:int(1, 100) <= 45 then
      array[i] = random_scalar(rng, rapidjson)
    else
      array[i] = generate_random_value(rng, rapidjson, depth + 1, max_depth)
    end
  end

  return array
end

function generate_random_value(rng, rapidjson, depth, max_depth)
  if depth >= max_depth then
    return random_scalar(rng, rapidjson)
  end

  if rng:bool() then
    return generate_random_object(rng, rapidjson, depth, max_depth)
  end

  return generate_random_array(rng, rapidjson, depth, max_depth)
end

local function generate_random_payload(rng, rapidjson)
  local max_depth = rng:int(3, 6)
  local random_core = generate_random_object(rng, rapidjson, 1, max_depth)

  random_core[unique_random_key(rng, random_core)] =
    generate_random_array(rng, rapidjson, 2, max_depth)
  random_core[unique_random_key(rng, random_core)] =
    generate_random_object(rng, rapidjson, 2, max_depth)

  return {
    random = random_core,
    empty_object = {},
    empty_array = empty_json_array(),
    scalar_samples = {
      boolean = rng:bool(),
      empty_string = '',
      float = random_float(rng),
      integer = random_integer(rng),
      null_value = json_null(rapidjson),
      string = random_string(rng),
    },
  }
end

local function string_keys(value)
  local keys = {}

  for key in pairs(value) do
    if type(key) == 'string' then
      keys[#keys + 1] = key
    end
  end

  table.sort(keys)
  return keys
end

local function path_value(path)
  if path == nil or path == '' then
    return '$'
  end
  return path
end

local function is_json_null(value, rapidjson)
  return value == json_null(rapidjson)
end

local function is_json_array(value)
  local metatable = getmetatable(value)
  if metatable and metatable.__jsontype == 'array' then
    return true
  end

  local count = 0
  local max_index = 0

  for key in pairs(value) do
    if type(key) ~= 'number' or key < 1 or key % 1 ~= 0 then
      return false
    end

    count = count + 1
    if key > max_index then
      max_index = key
    end
  end

  return count > 0 and max_index == count
end

local function scalar_metadata(value, rapidjson)
  if is_json_null(value, rapidjson) then
    return 'null'
  end

  if value == '' then
    return 'empty_string'
  end

  if type(value) == 'number' and value == math.floor(value) then
    return 'integer'
  end

  if type(value) == 'number' then
    return 'float'
  end

  return type(value)
end

local function table_key_count(value)
  local count = 0

  for _ in pairs(value) do
    count = count + 1
  end

  return count
end

local function decoded_kind(value, rapidjson)
  if type(value) == 'table' and not is_json_null(value, rapidjson) then
    if is_json_array(value) then
      return 'array'
    end

    return 'object'
  end

  return scalar_metadata(value, rapidjson)
end

local function matches_expected_kind(value, expected_kind, rapidjson, expected_length)
  if expected_kind == 'object' then
    return type(value) == 'table' and not is_json_null(value, rapidjson) and not is_json_array(value)
  end

  if expected_kind == 'array' then
    if type(value) ~= 'table' or is_json_null(value, rapidjson) then
      return false
    end

    return is_json_array(value) or (expected_length == 0 and table_key_count(value) == 0)
  end

  return scalar_metadata(value, rapidjson) == expected_kind
end

local function lookup_path(value, path)
  if path == '$' then
    return true, value
  end

  if type(path) ~= 'string' or path:sub(1, 1) ~= '$' then
    return false, nil, 'invalid path: ' .. tostring(path)
  end

  local current = value
  local offset = 2

  while offset <= #path do
    local char = path:sub(offset, offset)

    if char == '.' then
      offset = offset + 1

      local start = offset
      while offset <= #path do
        local next_char = path:sub(offset, offset)
        if next_char == '.' or next_char == '[' then
          break
        end
        offset = offset + 1
      end

      if start == offset then
        return false, nil, 'invalid path segment: ' .. path
      end

      if type(current) ~= 'table' then
        return false, nil, 'path not found: ' .. path
      end

      current = current[path:sub(start, offset - 1)]
      if current == nil then
        return false, nil, 'path not found: ' .. path
      end
    elseif char == '[' then
      local close = path:find(']', offset + 1, true)
      if close == nil then
        return false, nil, 'invalid path segment: ' .. path
      end

      local index = tonumber(path:sub(offset + 1, close - 1))
      if index == nil or index < 1 or index % 1 ~= 0 then
        return false, nil, 'invalid array index: ' .. path
      end

      if type(current) ~= 'table' then
        return false, nil, 'path not found: ' .. path
      end

      current = current[index]
      if current == nil then
        return false, nil, 'path not found: ' .. path
      end

      offset = close + 1
    else
      return false, nil, 'invalid path segment: ' .. path
    end
  end

  return true, current
end

local function format_keys(keys)
  return table.concat(keys, ',')
end

local function find_key_token(json, key, start, rapidjson)
  local token = rapidjson.encode(key)
  local offset = start

  while true do
    local first, last = json:find(token, offset, true)
    if first == nil then
      return nil
    end

    if json:sub(last + 1):match('^%s*:') then
      return first
    end

    offset = last + 1
  end
end

local function validate_key_order(rapidjson, json, object_entry)
  local offset = 1
  local previous_key

  for _, key in ipairs(object_entry.keys or {}) do
    local position = find_key_token(json, key, offset, rapidjson)
    if position == nil then
      if previous_key == nil then
        return false, string.format(
          'key order mismatch at %s: missing key %s',
          object_entry.path,
          key
        )
      end

      return false, string.format(
        'key order mismatch at %s: expected key %s after %s',
        object_entry.path,
        key,
        previous_key
      )
    end

    previous_key = key
    offset = position + 1
  end

  return true
end

local function loaded_null(value, rapidjson)
  if rapidjson and rapidjson.null ~= nil and value == rapidjson.null then
    return true
  end

  local loaded = package.loaded.rapidjson
  return loaded ~= nil and loaded.null ~= nil and value == loaded.null
end

local function dump_string(value)
  local truncated = value
  if #truncated > 120 then
    truncated = truncated:sub(1, 117) .. '...'
  end

  return string.format('%q', truncated)
end

local function dump_value_inner(value, rapidjson, depth, seen)
  if loaded_null(value, rapidjson) then
    return 'null'
  end

  local value_type = type(value)
  if value_type == 'string' then
    return dump_string(value)
  end
  if value_type == 'number' or value_type == 'boolean' or value_type == 'nil' then
    return tostring(value)
  end
  if value_type ~= 'table' then
    return '<' .. value_type .. ':' .. tostring(value) .. '>'
  end

  if seen[value] then
    return '<cycle>'
  end
  if depth >= 5 then
    return is_json_array(value) and '[...]' or '{...}'
  end

  seen[value] = true

  local parts = {}
  if is_json_array(value) then
    local limit = math.min(#value, 12)
    for index = 1, limit do
      parts[#parts + 1] = dump_value_inner(value[index], rapidjson, depth + 1, seen)
    end
    if #value > limit then
      parts[#parts + 1] = '...'
    end
    seen[value] = nil
    return '[' .. table.concat(parts, ',') .. ']'
  end

  local keys = string_keys(value)
  local limit = math.min(#keys, 12)
  for index = 1, limit do
    local key = keys[index]
    parts[#parts + 1] =
      dump_string(key) .. '=' .. dump_value_inner(value[key], rapidjson, depth + 1, seen)
  end
  if #keys > limit then
    parts[#parts + 1] = '...'
  end

  seen[value] = nil
  return '{' .. table.concat(parts, ',') .. '}'
end

function M.dump_value(value)
  return dump_value_inner(value, nil, 1, {})
end

function M.format_failure(details)
  details = details or {}

  local case = details.case or {}
  local case_id = details.case_id or case.id or '?'
  local kind = details.kind or case.kind or '?'
  local schema = details.schema or case.schema or '?'
  local value = details.value
  if value == nil then
    value = case.value
  end

  local lines = {
    'FUZZ FAILURE',
    'seed=' .. tostring(details.seed or '?'),
    'worker=' .. tostring(details.worker or details.worker_id or '?'),
    'case=' .. tostring(case_id),
    'kind=' .. tostring(kind),
    'schema=' .. tostring(schema),
    'reason=' .. tostring(details.reason or '?'),
    'value=' .. M.dump_value(value),
  }

  if details.json ~= nil then
    lines[#lines + 1] = 'json=' .. tostring(details.json)
  end

  return table.concat(lines, '\n')
end

function M.validate_encoded_case(rapidjson, case, json)
  local ok, decoded, decode_err = pcall(rapidjson.decode, json)
  if not ok then
    return false, 'decode failed: ' .. tostring(decoded)
  end
  if decoded == nil then
    return false, 'decode failed: ' .. tostring(decode_err or 'nil result')
  end

  local expected = case.expected or {}
  if expected.top_level_kind ~= nil and
    not matches_expected_kind(decoded, expected.top_level_kind, rapidjson) then
    return false, string.format(
      'top-level kind mismatch: expected %s got %s',
      expected.top_level_kind,
      decoded_kind(decoded, rapidjson)
    )
  end

  for _, entry in ipairs(expected.objects or {}) do
    local found, value, err = lookup_path(decoded, entry.path)
    if not found then
      return false, err
    end

    if not matches_expected_kind(value, 'object', rapidjson) then
      return false, string.format(
        'object kind mismatch at %s: got %s',
        entry.path,
        decoded_kind(value, rapidjson)
      )
    end

    local actual_keys = string_keys(value)
    if #actual_keys ~= entry.key_count then
      return false, string.format(
        'object key count mismatch at %s: expected %d got %d',
        entry.path,
        entry.key_count,
        #actual_keys
      )
    end

    for index, key in ipairs(entry.keys or {}) do
      if actual_keys[index] ~= key then
        return false, string.format(
          'object keys mismatch at %s: expected %s got %s',
          entry.path,
          format_keys(entry.keys or {}),
          format_keys(actual_keys)
        )
      end
    end

    local ordered, order_err = validate_key_order(rapidjson, json, entry)
    if not ordered then
      return false, order_err
    end
  end

  for _, entry in ipairs(expected.arrays or {}) do
    local found, value, err = lookup_path(decoded, entry.path)
    if not found then
      return false, err
    end

    if not matches_expected_kind(value, 'array', rapidjson, entry.length) then
      return false, string.format(
        'array kind mismatch at %s: got %s',
        entry.path,
        decoded_kind(value, rapidjson)
      )
    end

    if #value ~= entry.length then
      return false, string.format(
        'array length mismatch at %s: expected %d got %d',
        entry.path,
        entry.length,
        #value
      )
    end
  end

  for _, entry in ipairs(expected.scalars or {}) do
    local found, value, err = lookup_path(decoded, entry.path)
    if not found then
      return false, err
    end

    local actual_kind = scalar_metadata(value, rapidjson)
    if actual_kind ~= entry.kind then
      return false, string.format(
        'scalar kind mismatch at %s: expected %s got %s',
        entry.path,
        entry.kind,
        actual_kind
      )
    end

    if entry.kind == 'null' then
      if value ~= json_null(rapidjson) then
        return false, 'scalar value mismatch at ' .. entry.path .. ': expected null'
      end
    elseif value ~= entry.value then
      return false, string.format(
        'scalar value mismatch at %s: expected %s got %s',
        entry.path,
        dump_value_inner(entry.value, rapidjson, 1, {}),
        dump_value_inner(value, rapidjson, 1, {})
      )
    end
  end

  return true, nil
end

local function track_object(expected, path, value)
  local keys = string_keys(value)

  expected.objects[#expected.objects + 1] = {
    path = path_value(path),
    key_count = #keys,
    keys = keys,
  }
end

local function track_array(expected, path, value)
  expected.arrays[#expected.arrays + 1] = {
    path = path_value(path),
    length = #value,
  }
end

local function track_scalar(expected, path, value, rapidjson)
  local kind = scalar_metadata(value, rapidjson)
  local entry = {
    path = path_value(path),
    kind = kind,
  }

  if kind ~= 'null' then
    entry.value = value
  end

  expected.scalars[#expected.scalars + 1] = entry
end

-- Schema shells track selected scalars only.
-- Recursive-core metadata is exhaustive for that generated core.
local function base_expected(top_level_kind)
  return {
    top_level_kind = top_level_kind,
    objects = {},
    arrays = {},
    scalars = {},
  }
end

local function collect_random_metadata(expected, value, path, rapidjson)
  local stats = {
    max_depth = 0,
    object_count = 0,
    array_count = 0,
    scalar_count = 0,
  }

  local function visit(node, current_path, depth)
    if depth > stats.max_depth then
      stats.max_depth = depth
    end

    if type(node) ~= 'table' or is_json_null(node, rapidjson) then
      stats.scalar_count = stats.scalar_count + 1
      track_scalar(expected, current_path, node, rapidjson)
      return
    end

    if is_json_array(node) then
      stats.array_count = stats.array_count + 1
      track_array(expected, current_path, node)

      for i = 1, #node do
        visit(node[i], current_path .. '[' .. tostring(i) .. ']', depth + 1)
      end

      return
    end

    stats.object_count = stats.object_count + 1
    track_object(expected, current_path, node)

    local keys = string_keys(node)
    for _, key in ipairs(keys) do
      visit(node[key], current_path .. '.' .. key, depth + 1)
    end
  end

  visit(value, path_value(path), 1)

  if expected.random == nil then
    expected.random = {
      max_depth = 0,
      object_count = 0,
      array_count = 0,
      scalar_count = 0,
    }
  end

  if stats.max_depth > expected.random.max_depth then
    expected.random.max_depth = stats.max_depth
  end
  expected.random.object_count = expected.random.object_count + stats.object_count
  expected.random.array_count = expected.random.array_count + stats.array_count
  expected.random.scalar_count = expected.random.scalar_count + stats.scalar_count

  return stats
end

local function collect_payload_metadata(expected, payload, path, rapidjson)
  track_object(expected, path, payload)
  track_object(expected, path .. '.empty_object', payload.empty_object)
  track_array(expected, path .. '.empty_array', payload.empty_array)
  track_object(expected, path .. '.scalar_samples', payload.scalar_samples)
  track_scalar(expected, path .. '.scalar_samples.boolean', payload.scalar_samples.boolean, rapidjson)
  track_scalar(
    expected,
    path .. '.scalar_samples.empty_string',
    payload.scalar_samples.empty_string,
    rapidjson
  )
  track_scalar(expected, path .. '.scalar_samples.float', payload.scalar_samples.float, rapidjson)
  track_scalar(expected, path .. '.scalar_samples.integer', payload.scalar_samples.integer, rapidjson)
  track_scalar(
    expected,
    path .. '.scalar_samples.null_value',
    payload.scalar_samples.null_value,
    rapidjson
  )
  track_scalar(expected, path .. '.scalar_samples.string', payload.scalar_samples.string, rapidjson)
  collect_random_metadata(expected, payload.random, path .. '.random', rapidjson)
end

local function build_llm_response(rng, rapidjson)
  local value = {
    id = 'chatcmpl-' .. tostring(rng:int(100000, 999999)),
    object = 'chat.completion',
    created = 1700000000 + rng:int(1, 100000),
    model = 'fuzz-model-' .. tostring(rng:int(1, 7)),
    choices = {
      {
        index = 0,
        message = {
          role = 'assistant',
          content = random_string(rng),
        },
        finish_reason = rng:choice({ 'stop', 'length', 'tool_calls' }),
      },
    },
    usage = {
      prompt_tokens = rng:int(1, 4096),
      completion_tokens = rng:int(1, 4096),
      total_tokens = 0,
    },
    fuzz = generate_random_payload(rng, rapidjson),
  }
  value.usage.total_tokens = value.usage.prompt_tokens + value.usage.completion_tokens

  local expected = base_expected('object')
  track_object(expected, '$', value)
  track_array(expected, '$.choices', value.choices)
  track_object(expected, '$.choices[1]', value.choices[1])
  track_object(expected, '$.choices[1].message', value.choices[1].message)
  track_object(expected, '$.usage', value.usage)
  track_scalar(expected, '$.id', value.id, rapidjson)
  track_scalar(expected, '$.model', value.model, rapidjson)
  track_scalar(expected, '$.choices[1].message.content', value.choices[1].message.content, rapidjson)
  track_scalar(expected, '$.usage.total_tokens', value.usage.total_tokens, rapidjson)
  collect_payload_metadata(expected, value.fuzz, '$.fuzz', rapidjson)

  return value, expected
end

local function build_github_issue(rng, rapidjson)
  local value = {
    number = rng:int(1, 25000),
    title = 'Issue: ' .. random_string(rng),
    state = rng:choice({ 'open', 'closed' }),
    locked = rng:bool(),
    user = {
      login = 'user-' .. tostring(rng:int(1, 9999)),
      id = rng:int(1, 999999),
      type = rng:choice({ 'User', 'Bot' }),
    },
    labels = {
      { name = 'bug', color = 'd73a4a' },
      { name = 'fuzz', color = '5319e7' },
    },
    assignees = {
      {
        login = 'maintainer-' .. tostring(rng:int(1, 99)),
        id = rng:int(1, 999999),
      },
    },
    comments = rng:int(0, 1000),
    reactions = {
      total_count = rng:int(0, 1000),
      plus_one = rng:int(0, 250),
      heart = rng:int(0, 250),
    },
    fuzz = generate_random_payload(rng, rapidjson),
  }

  local expected = base_expected('object')
  track_object(expected, '$', value)
  track_object(expected, '$.user', value.user)
  track_array(expected, '$.labels', value.labels)
  track_object(expected, '$.labels[1]', value.labels[1])
  track_object(expected, '$.labels[2]', value.labels[2])
  track_array(expected, '$.assignees', value.assignees)
  track_object(expected, '$.assignees[1]', value.assignees[1])
  track_object(expected, '$.reactions', value.reactions)
  track_scalar(expected, '$.number', value.number, rapidjson)
  track_scalar(expected, '$.title', value.title, rapidjson)
  track_scalar(expected, '$.state', value.state, rapidjson)
  track_scalar(expected, '$.locked', value.locked, rapidjson)
  collect_payload_metadata(expected, value.fuzz, '$.fuzz', rapidjson)

  return value, expected
end

local function build_social_feed(rng, rapidjson)
  local value = {
    feed_id = 'feed-' .. tostring(rng:int(1000, 9999)),
    generated_at = '2026-05-' .. tostring(rng:int(10, 29)) .. 'T12:00:00Z',
    viewer = {
      id = rng:int(1, 99999),
      handle = 'viewer-' .. tostring(rng:int(1, 999)),
      premium = rng:bool(),
    },
    posts = {
      {
        id = 'post-' .. tostring(rng:int(1, 999999)),
        body = random_string(rng),
        author = {
          handle = 'author-' .. tostring(rng:int(1, 999)),
          verified = rng:bool(),
        },
        media = {
          {
            type = 'image',
            url = 'https://example.test/media/' .. tostring(rng:int(1, 9999)),
          },
        },
        reactions = {
          likes = rng:int(0, 10000),
          reposts = rng:int(0, 10000),
        },
      },
    },
    fuzz = generate_random_payload(rng, rapidjson),
  }

  local expected = base_expected('object')
  track_object(expected, '$', value)
  track_object(expected, '$.viewer', value.viewer)
  track_array(expected, '$.posts', value.posts)
  track_object(expected, '$.posts[1]', value.posts[1])
  track_object(expected, '$.posts[1].author', value.posts[1].author)
  track_array(expected, '$.posts[1].media', value.posts[1].media)
  track_object(expected, '$.posts[1].media[1]', value.posts[1].media[1])
  track_object(expected, '$.posts[1].reactions', value.posts[1].reactions)
  track_scalar(expected, '$.feed_id', value.feed_id, rapidjson)
  track_scalar(expected, '$.posts[1].body', value.posts[1].body, rapidjson)
  track_scalar(expected, '$.viewer.premium', value.viewer.premium, rapidjson)
  collect_payload_metadata(expected, value.fuzz, '$.fuzz', rapidjson)

  return value, expected
end

local function build_paginated_list(rng, rapidjson)
  local value = {
    page = rng:int(1, 50),
    per_page = rng:choice({ 10, 25, 50, 100 }),
    total = rng:int(100, 10000),
    has_next = rng:bool(),
    links = {
      self = '/v1/items?page=1',
      next = '/v1/items?page=2',
      previous = json_null(rapidjson),
    },
    items = {
      {
        id = rng:int(1, 999999),
        name = random_string(rng),
        active = rng:bool(),
        attributes = {
          rank = rng:int(1, 100),
          score = random_float(rng),
        },
      },
      {
        id = rng:int(1, 999999),
        name = random_string(rng),
        active = rng:bool(),
        attributes = {
          rank = rng:int(1, 100),
          score = random_float(rng),
        },
      },
    },
    fuzz = generate_random_payload(rng, rapidjson),
  }

  local expected = base_expected('object')
  track_object(expected, '$', value)
  track_object(expected, '$.links', value.links)
  track_array(expected, '$.items', value.items)
  track_object(expected, '$.items[1]', value.items[1])
  track_object(expected, '$.items[1].attributes', value.items[1].attributes)
  track_object(expected, '$.items[2]', value.items[2])
  track_object(expected, '$.items[2].attributes', value.items[2].attributes)
  track_scalar(expected, '$.page', value.page, rapidjson)
  track_scalar(expected, '$.per_page', value.per_page, rapidjson)
  track_scalar(expected, '$.has_next', value.has_next, rapidjson)
  track_scalar(expected, '$.links.previous', value.links.previous, rapidjson)
  collect_payload_metadata(expected, value.fuzz, '$.fuzz', rapidjson)

  return value, expected
end

local function build_metadata_config(rng, rapidjson)
  local value = {
    version = 'v' .. tostring(rng:int(1, 9)) .. '.' .. tostring(rng:int(0, 20)),
    environment = rng:choice({ 'dev', 'staging', 'prod' }),
    flags = {
      beta = rng:bool(),
      strict = rng:bool(),
      audit = rng:bool(),
    },
    limits = {
      requests_per_minute = rng:int(1, 10000),
      burst = rng:int(1, 1000),
      timeout_seconds = rng:int(1, 120),
    },
    tags = {
      'json',
      'encode',
      'fuzz',
    },
    rules = {
      {
        name = 'required-metadata',
        enabled = true,
        threshold = random_float(rng),
      },
      {
        name = 'optional-overrides',
        enabled = rng:bool(),
        threshold = random_float(rng),
      },
    },
    fuzz = generate_random_payload(rng, rapidjson),
  }

  local expected = base_expected('object')
  track_object(expected, '$', value)
  track_object(expected, '$.flags', value.flags)
  track_object(expected, '$.limits', value.limits)
  track_array(expected, '$.tags', value.tags)
  track_array(expected, '$.rules', value.rules)
  track_object(expected, '$.rules[1]', value.rules[1])
  track_object(expected, '$.rules[2]', value.rules[2])
  track_scalar(expected, '$.version', value.version, rapidjson)
  track_scalar(expected, '$.environment', value.environment, rapidjson)
  track_scalar(expected, '$.flags.strict', value.flags.strict, rapidjson)
  track_scalar(expected, '$.limits.requests_per_minute', value.limits.requests_per_minute, rapidjson)
  collect_payload_metadata(expected, value.fuzz, '$.fuzz', rapidjson)

  return value, expected
end

local SCHEMA_BUILDERS = {
  llm_response = build_llm_response,
  github_issue = build_github_issue,
  social_feed = build_social_feed,
  paginated_list = build_paginated_list,
  metadata_config = build_metadata_config,
}

function M.generate_case(rng, case_id, rapidjson)
  case_id = case_id or 1
  rng = rng or M.new_rng(case_id)
  json_null(rapidjson)

  local kind = CASE_KINDS[((case_id - 1) % #CASE_KINDS) + 1]

  if kind == 'schema_guided' then
    local schema_index = (math.floor((case_id - 1) / #CASE_KINDS) % #SCHEMA_FAMILIES) + 1
    local schema = SCHEMA_FAMILIES[schema_index]
    local value, expected = SCHEMA_BUILDERS[schema](rng, rapidjson)

    return {
      id = case_id,
      kind = kind,
      schema = schema,
      value = value,
      expected = expected,
    }
  end

  local value = generate_random_payload(rng, rapidjson)
  value.case_id = case_id

  local expected = base_expected('object')
  track_scalar(expected, '$.case_id', value.case_id, rapidjson)
  collect_payload_metadata(expected, value, '$', rapidjson)

  return {
    id = case_id,
    kind = kind,
    schema = 'recursive_random',
    value = value,
    expected = expected,
  }
end

return M
