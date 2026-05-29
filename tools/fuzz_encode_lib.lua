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

return M
