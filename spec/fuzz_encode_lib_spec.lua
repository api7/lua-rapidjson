require 'busted.runner'()

describe('tools.fuzz_encode_lib', function()
  local fuzz = require('tools.fuzz_encode_lib')
  local rapidjson = require('rapidjson')

  describe('parse_config', function()
    it('uses production defaults', function()
      local cfg = fuzz.parse_config({})

      assert.are.equal(3600, cfg.duration)
      assert.are.equal(5, cfg.interval)
      assert.are.equal(1, cfg.workers)
      assert.are.equal(1, cfg.worker_id)
      assert.are.equal(true, cfg.sort_keys)
      assert.are.equal(0, cfg.sample_interval)
      assert.are.equal(0, cfg.sample_limit)
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
        SAMPLE_INTERVAL = '3',
        SAMPLE_LIMIT = '10',
      })

      assert.are.equal(12, cfg.duration)
      assert.are.equal(3, cfg.interval)
      assert.are.equal(2, cfg.workers)
      assert.are.equal(2, cfg.worker_id)
      assert.are.equal(99, cfg.seed)
      assert.are.equal(false, cfg.sort_keys)
      assert.are.equal(3, cfg.sample_interval)
      assert.are.equal(10, cfg.sample_limit)
    end)

    it('defaults time-based sampling to 10 samples when enabled', function()
      local cfg = fuzz.parse_config({ SAMPLE_INTERVAL = '1' })

      assert.are.equal(1, cfg.sample_interval)
      assert.are.equal(10, cfg.sample_limit)
    end)

    it('treats numeric zero as disabling sorted keys', function()
      local cfg = fuzz.parse_config({ SORT_KEYS = 0 })

      assert.are.equal(false, cfg.sort_keys)
    end)
  end)

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
    it('generates deterministic schema-guided cases with selected metadata', function()
      local a = fuzz.generate_case(fuzz.new_rng(321), 1, rapidjson)
      local b = fuzz.generate_case(fuzz.new_rng(321), 1, rapidjson)

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
      local case = fuzz.generate_case(fuzz.new_rng(98765), 3, rapidjson)

      assert.are.equal('recursive_random', case.kind)
      assert.are.equal('recursive_random', case.schema)
      assert.are.equal('table', type(case.value))
      assert.are.equal('table', type(case.value.random))
      assert.are.equal('table', type(case.expected.random))
      assert.is_true(case.expected.random.max_depth >= 3)
      assert.is_true(case.expected.random.object_count >= 2)
      assert.is_true(case.expected.random.array_count >= 1)
      assert.is_true(#case.expected.objects >= case.expected.random.object_count)
      assert.is_true(#case.expected.arrays >= case.expected.random.array_count)
    end)

    it('tracks recursive random arrays from the generated core', function()
      local case = fuzz.generate_case(fuzz.new_rng(98765), 3, rapidjson)
      local saw_core_array = false

      for _, entry in ipairs(case.expected.arrays) do
        if entry.path:match('^%$%.random') then
          saw_core_array = true
        end
      end

      assert.is_true(saw_core_array)
    end)

    it('emits rapidjson null sentinels that round-trip as JSON null', function()
      local case = fuzz.generate_case(fuzz.new_rng(100), 10, rapidjson)

      assert.are.equal('paginated_list', case.schema)
      assert.are.equal(rapidjson.null, case.value.links.previous)

      local encoded = rapidjson.encode(case.value)
      local decoded = rapidjson.decode(encoded)

      assert.matches('"previous":null', encoded, 1, true)
      assert.are.equal(rapidjson.null, decoded.links.previous)
    end)

    it('requires a real rapidjson null sentinel', function()
      assert.has_error(function()
        fuzz.generate_case(fuzz.new_rng(1), 1, {})
      end, 'rapidjson.null is required')
    end)

    it('rejects fake table null sentinels', function()
      assert.has_error(function()
        fuzz.generate_case(fuzz.new_rng(1), 1, { null = {} })
      end, 'rapidjson.null is required')
    end)

    it('runs pure recursive random cases at least as often as schema-guided cases', function()
      local rng = fuzz.new_rng(1)
      local seen = {}
      local counts = {
        schema_guided = 0,
        recursive_random = 0,
      }

      for case_id = 1, 30 do
        local case = fuzz.generate_case(rng, case_id, rapidjson)
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

  describe('validate_encoded_case', function()
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
        kind = 'manual',
        schema = 'manual',
        value = { b = 1, a = 2 },
        expected = {
          top_level_kind = 'object',
          objects = {
            { path = '$', key_count = 2, keys = { 'a', 'b' } },
          },
          arrays = {},
          scalars = {},
        },
      }

      local ok, err = fuzz.validate_encoded_case(rapidjson, case, '{"b":1,"a":2}')

      assert.is_false(ok)
      assert.matches('key order', err, 1, true)
    end)

    it('rejects unsorted nested object keys for tracked object paths', function()
      local case = {
        id = 2,
        kind = 'manual',
        schema = 'manual',
        value = { a = { b = 1, a = 2 } },
        expected = {
          top_level_kind = 'object',
          objects = {
            { path = '$.a', key_count = 2, keys = { 'a', 'b' } },
          },
          arrays = {},
          scalars = {},
        },
      }

      local ok, err = fuzz.validate_encoded_case(rapidjson, case, '{"a":{"b":1,"a":2}}')

      assert.is_false(ok)
      assert.matches('key order', err, 1, true)
    end)

    it('validates recursive_random core metadata after encode and decode', function()
      local case = fuzz.generate_case(fuzz.new_rng(98765), 2, rapidjson)
      local json = rapidjson.encode(case.value, { sort_keys = true })

      assert.are.equal('recursive_random', case.kind)
      assert.are.equal('recursive_random', case.schema)
      assert.are.equal('table', type(case.expected.random))

      local ok, err = fuzz.validate_encoded_case(rapidjson, case, json)

      assert.is_true(ok)
      assert.is_nil(err)
    end)

    it('accepts small floating point round-trip differences', function()
      local case = {
        id = 3,
        kind = 'manual',
        schema = 'manual',
        value = { n = 12.931 },
        expected = {
          top_level_kind = 'object',
          objects = {
            { path = '$', key_count = 1, keys = { 'n' } },
          },
          arrays = {},
          scalars = {
            { path = '$.n', kind = 'float', value = 12.931 },
          },
        },
      }

      local ok, err = fuzz.validate_encoded_case(
        rapidjson,
        case,
        '{"n":12.931000000000001}'
      )

      assert.is_true(ok)
      assert.is_nil(err)
    end)

    it('returns decode diagnostics when JSON cannot be decoded', function()
      local ok, err = fuzz.validate_encoded_case(rapidjson, { expected = {} }, '{"a":}')

      assert.is_false(ok)
      assert.matches('decode failed:', err, 1, true)
    end)
  end)

  describe('format_failure', function()
    it('is reproducible and includes fuzz failure diagnostics', function()
      local case = {
        id = 42,
        kind = 'manual',
        schema = 'manual_schema',
        value = { b = 1, a = { true, rapidjson.null } },
      }
      local details = {
        seed = 12345,
        worker_id = 2,
        case = case,
        reason = 'key order mismatch at $',
        json = '{"b":1,"a":[true,null]}',
      }

      local first = fuzz.format_failure(details)
      local second = fuzz.format_failure(details)

      assert.are.equal(first, second)
      assert.matches('FUZZ FAILURE', first, 1, true)
      assert.matches('seed=12345', first, 1, true)
      assert.matches('worker=2', first, 1, true)
      assert.matches('case=42', first, 1, true)
      assert.matches('kind=manual', first, 1, true)
      assert.matches('schema=manual_schema', first, 1, true)
      assert.matches('reason=key order mismatch at $', first, 1, true)
      assert.matches('value=', first, 1, true)
      assert.matches('"a"', first, 1, true)
      assert.matches('json={"b":1,"a":[true,null]}', first, 1, true)
    end)
  end)

  describe('format_sample', function()
    it('prints full sample data with aligned value columns', function()
      local case = {
        id = 7,
        kind = 'manual',
        schema = 'manual_schema',
        value = {
          root = {
            child = {
              leaf = {
                value = 'deep-value',
              },
            },
          },
        },
      }

      local sample = fuzz.format_sample({
        seed = 123,
        worker_id = 1,
        elapsed = 2,
        case = case,
        raw_json_unsorted = '{"root":{"child":{"leaf":{"value":"deep-value"}}}}',
        encoded_json_sort_keys = '{"root":{"child":{"leaf":{"value":"deep-value"}}}}',
      })

      assert.matches('FUZZ SAMPLE', sample, 1, true)
      assert.matches('case=7', sample, 1, true)
      assert.matches('input_lua=             {', sample, 1, true)
      assert.matches('raw_json_unsorted=     {', sample, 1, true)
      assert.matches('encoded_json_sort_keys={', sample, 1, true)
      assert.matches('deep-value', sample, 1, true)
      assert.is_nil(sample:find('{...}', 1, true))
      assert.is_nil(sample:find('[...]', 1, true))
    end)
  end)
end)
