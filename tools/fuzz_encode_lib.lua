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
local FALLBACK_NULL = {}

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
  if rapidjson and rapidjson.null ~= nil then
    return rapidjson.null
  end
  return FALLBACK_NULL
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
  local payload = generate_random_object(rng, rapidjson, 1, max_depth)

  payload.empty_object = {}
  payload.empty_array = empty_json_array()
  payload.scalar_samples = {
    boolean = rng:bool(),
    empty_string = '',
    float = random_float(rng),
    integer = random_integer(rng),
    null_value = json_null(rapidjson),
    string = random_string(rng),
  }

  return payload
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
  collect_random_metadata(expected, value.fuzz, '$.fuzz', rapidjson)

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
  collect_random_metadata(expected, value.fuzz, '$.fuzz', rapidjson)

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
  collect_random_metadata(expected, value.fuzz, '$.fuzz', rapidjson)

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
  collect_random_metadata(expected, value.fuzz, '$.fuzz', rapidjson)

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
  collect_random_metadata(expected, value.fuzz, '$.fuzz', rapidjson)

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
  collect_random_metadata(expected, value, '$', rapidjson)

  return {
    id = case_id,
    kind = kind,
    schema = 'recursive_random',
    value = value,
    expected = expected,
  }
end

return M
