local rapidjson = require('rapidjson')
local fuzz = require('tools.fuzz_encode_lib')

local env = fuzz.env_from_args(arg)
for _, key in ipairs({
  'DURATION',
  'INTERVAL',
  'WORKERS',
  'WORKER_ID',
  'SEED',
  'SORT_KEYS',
  'SAMPLE_INTERVAL',
  'SAMPLE_LIMIT',
}) do
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
local last_report_total = -1
local last_report_elapsed = -1
local sample_count = 0
local next_sample_at = started

local function update_stats(now)
  stats.elapsed = now - started
  if stats.elapsed <= 0 then
    stats.rate = stats.total
  else
    stats.rate = stats.total / stats.elapsed
  end
end

local function print_summary()
  print(fuzz.format_summary(stats))
  last_report_total = stats.total
  last_report_elapsed = stats.elapsed
end

local function sample_limit_reached()
  return cfg.sample_limit > 0 and sample_count >= cfg.sample_limit
end

local function advance_next_sample_at(now)
  repeat
    next_sample_at = next_sample_at + cfg.sample_interval
  until next_sample_at > now
end

local function maybe_print_sample(generated_case, encoded_json, now)
  if cfg.sample_interval <= 0 or sample_limit_reached() or now < next_sample_at then
    return
  end

  local raw_ok, raw_json_or_err = pcall(rapidjson.encode, generated_case.value, {
    sort_keys = false,
  })
  local sorted_ok, sorted_json_or_err = true, encoded_json
  if not cfg.sort_keys then
    sorted_ok, sorted_json_or_err = pcall(rapidjson.encode, generated_case.value, {
      sort_keys = true,
    })
  end

  sample_count = sample_count + 1
  update_stats(now)
  print(fuzz.format_sample({
    rapidjson = rapidjson,
    seed = cfg.seed,
    worker_id = cfg.worker_id,
    elapsed = stats.elapsed,
    case = generated_case,
    raw_json_unsorted = raw_ok and raw_json_or_err or ('<encode failed: ' .. tostring(raw_json_or_err) .. '>'),
    encoded_json_sort_keys = sorted_ok and sorted_json_or_err or ('<encode failed: ' .. tostring(sorted_json_or_err) .. '>'),
  }))
  advance_next_sample_at(now)
end

while os.time() < deadline do
  local case_id = stats.total + 1
  local generated_case = fuzz.generate_case(rng, case_id, rapidjson)
  local ok, json_or_err = pcall(rapidjson.encode, generated_case.value, {
    sort_keys = cfg.sort_keys,
  })

  stats.total = stats.total + 1
  stats.last_case_id = case_id

  if ok then
    stats.encoded = stats.encoded + 1
    local valid, reason = fuzz.validate_encoded_case(rapidjson, generated_case, json_or_err)
    if not valid then
      stats.validation_failures = stats.validation_failures + 1
      update_stats(os.time())
      io.stderr:write(fuzz.format_failure({
        seed = cfg.seed,
        worker_id = cfg.worker_id,
        case = generated_case,
        json = json_or_err,
        reason = reason,
      }), '\n')
      os.exit(1)
    end
  else
    stats.encode_errors = stats.encode_errors + 1
    update_stats(os.time())
    io.stderr:write(fuzz.format_failure({
      seed = cfg.seed,
      worker_id = cfg.worker_id,
      case = generated_case,
      reason = 'encode failed: ' .. tostring(json_or_err),
    }), '\n')
    os.exit(1)
  end

  local now = os.time()
  if ok then
    maybe_print_sample(generated_case, json_or_err, now)
  end

  if now >= next_report then
    update_stats(now)
    print_summary()
    next_report = now + cfg.interval
  end
end

update_stats(os.time())
if stats.total ~= last_report_total or stats.elapsed ~= last_report_elapsed then
  print_summary()
end
