# RealReturn Engine Core — Implementation Plan (Phase 1 of 3)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the pure-Ruby calculation engine for real (inflation-adjusted) money-weighted returns and opportunity-cost benchmark comparison, as POROs under `app/models/real_return/`, with no Rails-model coupling and no dependency on real-world data (tested against synthetic series).

**Architecture:** Four plain Ruby objects under the `RealReturn` namespace — `Xirr` (money-weighted IRR solver), `ReferenceData::Bundled` (reads bundled annual CPI/benchmark YAML and interpolates by day-fraction), `Cpi` (annualized inflation + Fisher real return), `Benchmark` (counterfactual terminal value + money-weighted return + ranking). The algorithms are faithful ports of the already-validated RealReturn Python engine (`/Users/clintongao/coding/Finance/packages/engine/realreturn/{xirr,inflation,benchmarks}.py`). Data access goes through a small documented interface so a live source can replace the bundled reader later with no call-site changes.

**Tech Stack:** Ruby 3.4.4, Rails 7.2 (Zeitwerk autoloading maps `RealReturn::Xirr` → `app/models/real_return/xirr.rb`), Minitest + fixtures (`ActiveSupport::TestCase`), `YAML.safe_load`.

**Scope boundary (what this phase is NOT):** No `Account`/`Family` integration, no controller/view, and **no real `config/real_return/*.yml` data** — those are Phase 2 (domain integration, incl. the real-data sourcing task) and Phase 3 (UI). This phase produces a working, unit-tested calculation library.

**Conventions for every task below:**
- Run commands from the repo root: `cd ~/coding/maybe`.
- Ensure the rbenv Ruby is active. If `ruby -v` does not print `3.4.4`, prefix commands with `export PATH="$HOME/.rbenv/shims:$PATH"`.
- Follow Maybe's testing rules: Minitest + fixtures, `ActiveSupport::TestCase`, test only the critical math/behavior (never test Ruby/Rails itself).
- Keyword-argument and sign conventions are fixed across tasks — do not rename:
  - **Xirr flows**: `Array` of `[Date, Float]`. Sign: contributions/outflows **negative**, terminal/inflows **positive**.
  - **Benchmark contributions**: `Array` of `[Date, Float]` with **positive** amounts (money invested).
  - All date args are Ruby `Date`. Reference-data lookups take `on:` (a `Date`) and interpolate.

---

## File Structure

| File | Responsibility |
|---|---|
| `app/models/real_return/xirr.rb` | `RealReturn::Xirr` — money-weighted IRR (Newton → bisection → clamp). Pure; no data. |
| `app/models/real_return/reference_data.rb` | `RealReturn::ReferenceData` — documented read-only interface + `.default` factory (swap point). |
| `app/models/real_return/reference_data/bundled.rb` | `RealReturn::ReferenceData::Bundled` — loads annual YAML, interpolates by day-fraction, clamps at the latest year, returns `nil` before the earliest year. |
| `app/models/real_return/cpi.rb` | `RealReturn::Cpi` — annualized inflation, Fisher real return, beats-inflation. |
| `app/models/real_return/benchmark.rb` | `RealReturn::Benchmark` — growth multiple, counterfactual terminal value, counterfactual money-weighted return, annualized return, ranking. |
| `test/fixtures/files/real_return/cpi.sample.yml` | Synthetic CPI series for tests. |
| `test/fixtures/files/real_return/benchmarks.sample.yml` | Synthetic benchmark series (incl. region-keyed `real_estate`) for tests. |
| `test/models/real_return/{xirr,reference_data_bundled,cpi,benchmark}_test.rb` | Unit tests. |

---

## Task 0: Setup branch and commit planning docs

**Files:** none (git only)

- [ ] **Step 1: Confirm not on the default branch; create a feature branch**

```bash
cd ~/coding/maybe
git rev-parse --abbrev-ref HEAD          # if this prints "main", branch off it:
git checkout -b feature/real-return
```
Expected: now on `feature/real-return`.

- [ ] **Step 2: Commit the spec and this plan**

```bash
git add docs/superpowers/specs/2026-05-30-real-return-on-maybe-design.md \
        docs/superpowers/plans/2026-05-30-real-return-engine-core.md
git commit -m "docs(real_return): add design spec and engine-core plan"
```
Expected: one commit created on `feature/real-return`.

---

## Task 1: `RealReturn::Xirr` (money-weighted IRR solver)

Faithful port of `/Users/clintongao/coding/Finance/packages/engine/realreturn/xirr.py`.

**Files:**
- Create: `app/models/real_return/xirr.rb`
- Test: `test/models/real_return/xirr_test.rb`

- [ ] **Step 1: Write the failing test**

Create `test/models/real_return/xirr_test.rb`:

```ruby
require "test_helper"

class RealReturn::XirrTest < ActiveSupport::TestCase
  test "single in/out over one calendar year returns the simple rate" do
    flows = [ [ Date.new(2021, 1, 1), -1000.0 ], [ Date.new(2022, 1, 1), 1100.0 ] ]
    assert_in_delta 0.10, RealReturn::Xirr.compute(flows), 1e-4
  end

  test "multiple contributions converge to a positive rate" do
    # -1000 @ y0, -1000 @ y1, +2300 @ y2 solves 2300x^2 - 1000x - 1000 = 0 => r ~= 0.097
    flows = [
      [ Date.new(2020, 1, 1), -1000.0 ],
      [ Date.new(2021, 1, 1), -1000.0 ],
      [ Date.new(2022, 1, 1), 2300.0 ]
    ]
    rate = RealReturn::Xirr.compute(flows)
    assert rate > 0.08 && rate < 0.11, "expected ~0.097, got #{rate}"
  end

  test "returns nil when fewer than two flows" do
    assert_nil RealReturn::Xirr.compute([ [ Date.new(2021, 1, 1), -1000.0 ] ])
  end

  test "returns nil when all flows share a sign" do
    flows = [ [ Date.new(2021, 1, 1), -1000.0 ], [ Date.new(2022, 1, 1), -500.0 ] ]
    assert_nil RealReturn::Xirr.compute(flows)
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bin/rails test test/models/real_return/xirr_test.rb`
Expected: FAIL — `NameError: uninitialized constant RealReturn::Xirr`.

- [ ] **Step 3: Write the implementation**

Create `app/models/real_return/xirr.rb`:

```ruby
module RealReturn
  # Money-weighted annualized return (Actual/365). Faithful port of the validated
  # RealReturn Python solver: Newton's method, then bisection on [-0.9999, 10.0].
  module Xirr
    DAYS_PER_YEAR = 365.0

    module_function

    # flows: Array of [Date, Float]. Sign convention: outflows negative, inflows positive.
    # Returns Float rate, or nil if degenerate (need >= 2 flows with both signs).
    def compute(flows)
      return nil if flows.length < 2

      amounts = flows.map { |(_, a)| a }
      return nil if amounts.min >= 0 || amounts.max <= 0

      t0 = flows.map { |(d, _)| d }.min

      rate = 0.1
      100.times do
        denom = dnpv(rate, flows, t0)
        break if denom.abs < 1e-12

        nxt = rate - npv(rate, flows, t0) / denom
        break unless nxt.finite? && nxt > -1.0
        return nxt if (nxt - rate).abs < 1e-9

        rate = nxt
      end

      lo = -0.9999
      hi = 10.0
      f_lo = npv(lo, flows, t0)
      f_hi = npv(hi, flows, t0)
      return nil if f_lo * f_hi > 0

      200.times do
        mid = (lo + hi) / 2.0
        f_mid = npv(mid, flows, t0)
        return mid if f_mid.abs < 1e-7

        if f_lo * f_mid < 0
          hi = mid
        else
          lo = mid
          f_lo = f_mid
        end
      end

      (lo + hi) / 2.0
    end

    def npv(rate, flows, t0)
      flows.sum(0.0) do |(d, amount)|
        years = (d - t0).to_i / DAYS_PER_YEAR
        amount / (1.0 + rate)**years
      end
    end

    def dnpv(rate, flows, t0)
      flows.sum(0.0) do |(d, amount)|
        years = (d - t0).to_i / DAYS_PER_YEAR
        -years * amount / (1.0 + rate)**(years + 1.0)
      end
    end
  end
end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bin/rails test test/models/real_return/xirr_test.rb`
Expected: PASS (4 runs, 0 failures).

- [ ] **Step 5: Commit**

```bash
git add app/models/real_return/xirr.rb test/models/real_return/xirr_test.rb
git commit -m "feat(real_return): add Xirr money-weighted IRR solver"
```

---

## Task 2: `RealReturn::ReferenceData::Bundled` (annual series reader)

**Files:**
- Create: `app/models/real_return/reference_data.rb`
- Create: `app/models/real_return/reference_data/bundled.rb`
- Create: `test/fixtures/files/real_return/cpi.sample.yml`
- Create: `test/fixtures/files/real_return/benchmarks.sample.yml`
- Test: `test/models/real_return/reference_data_bundled_test.rb`

- [ ] **Step 1: Create the synthetic test fixtures**

Create `test/fixtures/files/real_return/cpi.sample.yml`:

```yaml
CN:
  2010: 100.0
  2011: 105.0
  2012: 110.0
US:
  2010: 100.0
  2011: 103.0
```

Create `test/fixtures/files/real_return/benchmarks.sample.yml`:

```yaml
sp500:
  2010: 1.00
  2011: 1.20
  2012: 1.50
real_estate:
  CN:
    2010: 1.00
    2011: 1.10
    2012: 1.21
  US:
    2010: 1.00
    2011: 1.05
```

- [ ] **Step 2: Write the failing test**

Create `test/models/real_return/reference_data_bundled_test.rb`:

```ruby
require "test_helper"

class RealReturn::ReferenceData::BundledTest < ActiveSupport::TestCase
  setup do
    dir = Rails.root.join("test", "fixtures", "files", "real_return")
    @data = RealReturn::ReferenceData::Bundled.new(
      cpi_path: dir.join("cpi.sample.yml"),
      benchmarks_path: dir.join("benchmarks.sample.yml")
    )
  end

  test "cpi_index returns the exact value on a year boundary" do
    assert_in_delta 105.0, @data.cpi_index(area: "CN", on: Date.new(2011, 1, 1)), 1e-9
  end

  test "cpi_index interpolates by day-fraction within a year" do
    # 2011-07-02 is day 182 of a 365-day year -> fraction ~0.4986 between 105 and 110
    value = @data.cpi_index(area: "CN", on: Date.new(2011, 7, 2))
    assert value > 107.0 && value < 108.0, "expected ~107.5, got #{value}"
  end

  test "cpi_index clamps to the latest year and is nil before the earliest" do
    assert_in_delta 110.0, @data.cpi_index(area: "CN", on: Date.new(2012, 6, 1)), 1e-9
    assert_nil @data.cpi_index(area: "CN", on: Date.new(2009, 1, 1))
  end

  test "benchmark_level reads a flat series and a region-keyed series" do
    assert_in_delta 1.20, @data.benchmark_level(key: "sp500", on: Date.new(2011, 1, 1)), 1e-9
    assert_in_delta 1.10, @data.benchmark_level(key: "real_estate", on: Date.new(2011, 1, 1), region: "CN"), 1e-9
  end

  test "ranges report the covered years" do
    assert_equal (Date.new(2010, 1, 1)..Date.new(2012, 1, 1)), @data.cpi_range(area: "CN")
    assert_nil @data.cpi_range(area: "ZZ")
  end
end
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `bin/rails test test/models/real_return/reference_data_bundled_test.rb`
Expected: FAIL — `NameError: uninitialized constant RealReturn::ReferenceData`.

- [ ] **Step 4: Write the interface**

Create `app/models/real_return/reference_data.rb`:

```ruby
module RealReturn
  # Read-only access to bundled reference series (CPI + benchmarks).
  #
  # Interface contract (implementations provide these instance methods; all `on:`
  # arguments are a Date and values are interpolated by day-fraction between years):
  #   #cpi_index(area:, on:)               -> Float | nil
  #   #benchmark_level(key:, on:, region:) -> Float | nil   (region: defaults to nil)
  #   #cpi_range(area:)                    -> (Date..Date) | nil
  #   #benchmark_range(key:, region:)      -> (Date..Date) | nil
  module ReferenceData
    # Swap point for a future live source. Phase 2 points the bundled reader at
    # config/real_return/*.yml; callers depend only on this factory.
    def self.default
      @default ||= Bundled.new
    end
  end
end
```

- [ ] **Step 5: Write the bundled reader**

Create `app/models/real_return/reference_data/bundled.rb`:

```ruby
module RealReturn
  module ReferenceData
    # Loads annual reference series from YAML and interpolates by day-fraction.
    # Series shape: { "area_or_key" => { year(Integer) => level(Float) } }.
    # Region-keyed series (e.g. real_estate): { "key" => { "region" => { year => level } } }.
    class Bundled
      DEFAULT_CPI_PATH = Rails.root.join("config", "real_return", "cpi.yml")
      DEFAULT_BENCHMARKS_PATH = Rails.root.join("config", "real_return", "benchmarks.yml")

      def initialize(cpi_path: DEFAULT_CPI_PATH, benchmarks_path: DEFAULT_BENCHMARKS_PATH)
        @cpi_path = cpi_path
        @benchmarks_path = benchmarks_path
      end

      def cpi_index(area:, on:)
        interpolate(cpi_series(area), on)
      end

      def benchmark_level(key:, on:, region: nil)
        interpolate(benchmark_series(key, region), on)
      end

      def cpi_range(area:)
        series_range(cpi_series(area))
      end

      def benchmark_range(key:, region: nil)
        series_range(benchmark_series(key, region))
      end

      private
        def cpi_data
          @cpi_data ||= load_yaml(@cpi_path)
        end

        def benchmark_data
          @benchmark_data ||= load_yaml(@benchmarks_path)
        end

        def load_yaml(path)
          YAML.safe_load(File.read(path), permitted_classes: [], permitted_symbols: [], aliases: true)
        end

        def cpi_series(area)
          raw = cpi_data[area.to_s]
          raw && normalize_years(raw)
        end

        def benchmark_series(key, region)
          raw = benchmark_data[key.to_s]
          return nil if raw.nil?

          # Region-keyed series (e.g. real_estate) nest one more level: { region => { year => level } }.
          if raw.values.first.is_a?(Hash)
            return nil if region.nil?

            raw = raw[region.to_s]
            return nil if raw.nil?
          end

          normalize_years(raw)
        end

        def normalize_years(hash)
          hash.transform_keys(&:to_i).transform_values(&:to_f)
        end

        def series_range(series)
          return nil if series.nil? || series.empty?

          years = series.keys
          Date.new(years.min, 1, 1)..Date.new(years.max, 1, 1)
        end

        # Linear interpolation by day-fraction between consecutive years.
        # Before the earliest year -> nil (out of range). On/after the latest year
        # -> clamp to the latest level (handles the current, partial year).
        def interpolate(series, on)
          return nil if series.nil? || series.empty?

          min_year = series.keys.min
          max_year = series.keys.max
          return nil if on < Date.new(min_year, 1, 1)
          return series[max_year] if on >= Date.new(max_year, 1, 1)

          y = on.year
          lo = series[y]
          hi = series[y + 1]
          return nil if lo.nil? || hi.nil?

          year_start = Date.new(y, 1, 1)
          next_start = Date.new(y + 1, 1, 1)
          fraction = (on - year_start).to_f / (next_start - year_start).to_f
          lo + fraction * (hi - lo)
        end
      end
  end
end
```

- [ ] **Step 6: Run the test to verify it passes**

Run: `bin/rails test test/models/real_return/reference_data_bundled_test.rb`
Expected: PASS (5 runs, 0 failures).

- [ ] **Step 7: Commit**

```bash
git add app/models/real_return/reference_data.rb \
        app/models/real_return/reference_data/bundled.rb \
        test/fixtures/files/real_return/cpi.sample.yml \
        test/fixtures/files/real_return/benchmarks.sample.yml \
        test/models/real_return/reference_data_bundled_test.rb
git commit -m "feat(real_return): add bundled reference-data reader with interpolation"
```

---

## Task 3: `RealReturn::Cpi` (inflation + real return)

Port of `/Users/clintongao/coding/Finance/packages/engine/realreturn/inflation.py`.

**Files:**
- Create: `app/models/real_return/cpi.rb`
- Test: `test/models/real_return/cpi_test.rb`

- [ ] **Step 1: Write the failing test**

Create `test/models/real_return/cpi_test.rb`:

```ruby
require "test_helper"

class RealReturn::CpiTest < ActiveSupport::TestCase
  setup do
    dir = Rails.root.join("test", "fixtures", "files", "real_return")
    data = RealReturn::ReferenceData::Bundled.new(
      cpi_path: dir.join("cpi.sample.yml"),
      benchmarks_path: dir.join("benchmarks.sample.yml")
    )
    @cpi = RealReturn::Cpi.new(reference_data: data)
  end

  test "annualized inflation over two years" do
    # CN 100 -> 110 over 730 days => 1.1**(365/730) - 1 ~= 0.04881
    rate = @cpi.annualized(area: "CN", from: Date.new(2010, 1, 1), to: Date.new(2012, 1, 1))
    assert_in_delta 0.04881, rate, 1e-4
  end

  test "real return deflates the nominal rate" do
    real = @cpi.real_return(nominal: 0.10, area: "CN", from: Date.new(2010, 1, 1), to: Date.new(2012, 1, 1))
    assert_in_delta 0.0488, real, 1e-3
  end

  test "beats_inflation compares nominal to inflation" do
    args = { area: "CN", from: Date.new(2010, 1, 1), to: Date.new(2012, 1, 1) }
    assert_equal true, @cpi.beats_inflation?(nominal: 0.10, **args)
    assert_equal false, @cpi.beats_inflation?(nominal: 0.02, **args)
  end

  test "fisher is a pure helper" do
    assert_in_delta 0.047619, RealReturn::Cpi.fisher(nominal: 0.10, inflation: 0.05), 1e-6
  end

  test "returns nil when CPI data is unavailable" do
    assert_nil @cpi.annualized(area: "ZZ", from: Date.new(2010, 1, 1), to: Date.new(2012, 1, 1))
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bin/rails test test/models/real_return/cpi_test.rb`
Expected: FAIL — `NameError: uninitialized constant RealReturn::Cpi`.

- [ ] **Step 3: Write the implementation**

Create `app/models/real_return/cpi.rb`:

```ruby
module RealReturn
  # Inflation math over a CPI index. Annualization uses Actual/365.
  class Cpi
    def initialize(reference_data: ReferenceData.default)
      @reference_data = reference_data
    end

    # Annualized inflation for `area` between two dates. nil if data unavailable.
    def annualized(area:, from:, to:)
      i0 = @reference_data.cpi_index(area: area, on: from)
      i1 = @reference_data.cpi_index(area: area, on: to)
      days = (to - from).to_i
      return nil if i0.nil? || i1.nil? || i0 <= 0 || days <= 0

      (i1 / i0)**(365.0 / days) - 1.0
    end

    # Inflation-adjusted annualized return. nil if inflation unavailable.
    def real_return(nominal:, area:, from:, to:)
      inflation = annualized(area: area, from: from, to: to)
      return nil if inflation.nil?

      self.class.fisher(nominal: nominal, inflation: inflation)
    end

    # true/false whether the nominal rate beat inflation; nil if unavailable.
    def beats_inflation?(nominal:, area:, from:, to:)
      inflation = annualized(area: area, from: from, to: to)
      return nil if inflation.nil?

      nominal > inflation
    end

    # Pure Fisher equation: (1 + nominal) / (1 + inflation) - 1.
    def self.fisher(nominal:, inflation:)
      (1.0 + nominal) / (1.0 + inflation) - 1.0
    end
  end
end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bin/rails test test/models/real_return/cpi_test.rb`
Expected: PASS (5 runs, 0 failures).

- [ ] **Step 5: Commit**

```bash
git add app/models/real_return/cpi.rb test/models/real_return/cpi_test.rb
git commit -m "feat(real_return): add Cpi inflation and real-return math"
```

---

## Task 4: `RealReturn::Benchmark` (counterfactual opportunity cost)

Port of the counterfactual/growth/league functions in `/Users/clintongao/coding/Finance/packages/engine/realreturn/benchmarks.py`.

**Files:**
- Create: `app/models/real_return/benchmark.rb`
- Test: `test/models/real_return/benchmark_test.rb`

- [ ] **Step 1: Write the failing test**

Create `test/models/real_return/benchmark_test.rb`:

```ruby
require "test_helper"

class RealReturn::BenchmarkTest < ActiveSupport::TestCase
  setup do
    dir = Rails.root.join("test", "fixtures", "files", "real_return")
    data = RealReturn::ReferenceData::Bundled.new(
      cpi_path: dir.join("cpi.sample.yml"),
      benchmarks_path: dir.join("benchmarks.sample.yml")
    )
    @bench = RealReturn::Benchmark.new(reference_data: data)
  end

  test "growth is the level ratio between two dates" do
    g = @bench.growth(key: "sp500", from: Date.new(2010, 1, 1), to: Date.new(2012, 1, 1))
    assert_in_delta 1.5, g, 1e-9
  end

  test "counterfactual terminal scales each contribution by its growth" do
    contributions = [ [ Date.new(2010, 1, 1), 1000.0 ] ]
    terminal = @bench.counterfactual_terminal(contributions: contributions, key: "sp500", as_of: Date.new(2012, 1, 1))
    assert_in_delta 1500.0, terminal, 1e-6
  end

  test "counterfactual return is the money-weighted rate of the counterfactual" do
    contributions = [ [ Date.new(2010, 1, 1), 1000.0 ] ]
    # terminal 1500 over 730 days => 1.5**(365/730) - 1 ~= 0.2247
    rate = @bench.counterfactual_return(contributions: contributions, key: "sp500", as_of: Date.new(2012, 1, 1))
    assert_in_delta 0.2247, rate, 1e-3
  end

  test "returns nil when the benchmark series is missing" do
    contributions = [ [ Date.new(2010, 1, 1), 1000.0 ] ]
    assert_nil @bench.counterfactual_return(contributions: contributions, key: "missing", as_of: Date.new(2012, 1, 1))
  end

  test "rank orders rows high to low with nils last" do
    ranked = RealReturn::Benchmark.rank([ [ "a", 0.1 ], [ "b", nil ], [ "c", 0.3 ] ])
    assert_equal [ "c", "a", "b" ], ranked.map(&:first)
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bin/rails test test/models/real_return/benchmark_test.rb`
Expected: FAIL — `NameError: uninitialized constant RealReturn::Benchmark`.

- [ ] **Step 3: Write the implementation**

Create `app/models/real_return/benchmark.rb`:

```ruby
module RealReturn
  # Opportunity-cost comparison: what the same money, contributed on the same dates,
  # would be worth in a benchmark vehicle. Faithful port of the validated Python engine.
  class Benchmark
    def initialize(reference_data: ReferenceData.default)
      @reference_data = reference_data
    end

    # Multiple that 1 unit invested at `from` becomes by `to`. nil if unavailable.
    def growth(key:, from:, to:, region: nil)
      v0 = @reference_data.benchmark_level(key: key, on: from, region: region)
      v1 = @reference_data.benchmark_level(key: key, on: to, region: region)
      return nil if v0.nil? || v1.nil? || v0 <= 0

      v1 / v0
    end

    # Terminal value of investing each contribution (positive amount, at its date)
    # into `key` and holding to `as_of`. nil if any growth factor is unavailable.
    def counterfactual_terminal(contributions:, key:, as_of:, region: nil)
      terminal = 0.0
      contributions.each do |(date, amount)|
        g = growth(key: key, from: date, to: as_of, region: region)
        return nil if g.nil?

        terminal += amount * g
      end
      terminal
    end

    # Money-weighted return (XIRR) of the counterfactual. nil if unavailable.
    def counterfactual_return(contributions:, key:, as_of:, region: nil)
      return nil if contributions.empty?

      terminal = counterfactual_terminal(contributions: contributions, key: key, as_of: as_of, region: region)
      return nil if terminal.nil?

      flows = contributions.map { |(date, amount)| [ date, -amount ] }
      flows << [ as_of, terminal ]
      RealReturn::Xirr.compute(flows)
    end

    # Annualized return of `key` over [from, to] (Actual/365). nil if unavailable.
    def annualized(key:, from:, to:, region: nil)
      g = growth(key: key, from: from, to: to, region: region)
      days = (to - from).to_i
      return nil if g.nil? || g <= 0 || days <= 0

      g**(365.0 / days) - 1.0
    end

    # Rank [label, value] rows high -> low; nil values last.
    def self.rank(rows)
      rows.sort_by { |(_, value)| [ value.nil? ? 1 : 0, -(value || 0.0) ] }
    end
  end
end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bin/rails test test/models/real_return/benchmark_test.rb`
Expected: PASS (6 runs, 0 failures).

- [ ] **Step 5: Run the whole RealReturn suite together**

Run: `bin/rails test test/models/real_return/`
Expected: PASS (all four test files, 0 failures, 0 errors).

- [ ] **Step 6: Commit**

```bash
git add app/models/real_return/benchmark.rb test/models/real_return/benchmark_test.rb
git commit -m "feat(real_return): add Benchmark counterfactual and ranking"
```

---

## Done criteria for Phase 1

- `bin/rails test test/models/real_return/` passes (4 files).
- `RealReturn::Xirr`, `RealReturn::Cpi`, `RealReturn::Benchmark`, and `RealReturn::ReferenceData::Bundled` exist and are unit-tested against synthetic series.
- No real-world data files, no `Account`/`Family`/controller coupling yet.

**Next:** Phase 2 (domain integration) — `RealReturn::Analysis` (per-account cashflow extraction + valuation resolution), `RealReturn::PortfolioReport`, `Account#real_return`, plus the real-data sourcing task that assembles `config/real_return/{cpi,benchmarks}.yml` from cited public sources. To be written after Phase 1 lands and its tests pass.
