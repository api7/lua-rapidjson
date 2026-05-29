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
