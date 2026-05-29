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

    it('treats numeric zero as disabling sorted keys', function()
      local cfg = fuzz.parse_config({ SORT_KEYS = 0 })

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

  describe('generate_case', function()
    it('generates deterministic schema-guided cases with metadata', function()
      local a = fuzz.generate_case(fuzz.new_rng(321), 1, { null = {} })
      local b = fuzz.generate_case(fuzz.new_rng(321), 1, { null = {} })

      assert.are.same(a.value, b.value)
      assert.are.same(a.expected, b.expected)
      assert.are.equal('number', type(a.id))
      assert.are.equal('string', type(a.schema))
      assert.are.equal('schema_guided', a.kind)
      assert.are.equal('object', a.expected.top_level_kind)
      assert.are.equal('table', type(a.value.fuzz))
      assert.is_true(#a.expected.objects >= 1)
      assert.is_true(#a.expected.arrays >= 1)
      assert.is_true(#a.expected.scalars >= 1)
    end)

    it('adds pure recursive random cases with nested objects and arrays', function()
      local case = fuzz.generate_case(fuzz.new_rng(98765), 3, { null = {} })

      assert.are.equal('recursive_random', case.kind)
      assert.are.equal('recursive_random', case.schema)
      assert.are.equal('table', type(case.value))
      assert.are.equal('table', type(case.expected.random))
      assert.is_true(case.expected.random.max_depth >= 3)
      assert.is_true(case.expected.random.object_count >= 2)
      assert.is_true(case.expected.random.array_count >= 1)
      assert.is_true(#case.expected.objects >= case.expected.random.object_count)
      assert.is_true(#case.expected.arrays >= case.expected.random.array_count)
    end)

    it('runs pure recursive random cases at least as often as schema-guided cases', function()
      local rng = fuzz.new_rng(1)
      local seen = {}
      local counts = {
        schema_guided = 0,
        recursive_random = 0,
      }

      for case_id = 1, 30 do
        local case = fuzz.generate_case(rng, case_id, { null = {} })
        counts[case.kind] = counts[case.kind] + 1
        if case.kind == 'schema_guided' then
          seen[case.schema] = true
        end
      end

      assert.is_true(counts.recursive_random >= counts.schema_guided)
      assert.are.equal(10, counts.schema_guided)
      assert.are.equal(20, counts.recursive_random)
      assert.is_true(seen.llm_response)
      assert.is_true(seen.github_issue)
      assert.is_true(seen.social_feed)
      assert.is_true(seen.paginated_list)
      assert.is_true(seen.metadata_config)
    end)
  end)
end)
