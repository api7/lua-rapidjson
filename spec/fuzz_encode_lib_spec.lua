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
