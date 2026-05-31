# RealReturn Domain Integration + Real Data — Implementation Plan (Phase 2 of 3)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wire the Phase-1 engine to Maybe's real data — extract per-account cashflows from the ledger, resolve property current-value (user value else house-index estimate), aggregate at the family level, expose `Account#real_return` / `Family#real_return_report`, and bundle real CPI/benchmark series.

**Architecture:** `RealReturn::Analysis` (per `Account`) extracts signed cashflows by accountable type, normalizes to `family.currency` via `Money#exchange_to`, and answers nominal/real/benchmark questions using the Phase-1 POROs. `RealReturn::PortfolioReport` (per `Family`) merges all in-scope asset accounts' cashflows into one schedule for portfolio-level metrics + a benchmark league table. A tiny `RealReturn::Region` maps currency→CPI/real-estate region and holds the benchmark key list. Real annual data lives in `config/real_return/{cpi,benchmarks}.yml`, read by the Phase-1 `ReferenceData::Bundled` at its default paths.

**Tech Stack:** Ruby 3.4.4 / Rails 7.2, Minitest + the existing `LedgerTestingHelper#create_account_with_ledger` and `EntriesTestHelper`, `Money#exchange_to`, Zeitwerk autoloading.

**Depends on:** Phase 1 (`RealReturn::Xirr`, `::Cpi`, `::Benchmark`, `::ReferenceData::Bundled`) — already merged on branch `feature/real-return`.

**Conventions (unchanged from Phase 1):**
- Run from `/Users/clintongao/coding/maybe`; if `ruby -v` ≠ 3.4.4, prefix with `export PATH="$HOME/.rbenv/shims:$PATH"; `.
- Cashflow sign: outflows/contributions **negative**, terminal/inflows **positive** (Xirr convention). Benchmark `contributions` are **positive** amounts.
- Terminal value is derived **from the ledger**, never from `account.balance` (which is sync-derived and unreliable in unit tests).
- In-scope asset accountables: `Investment, Crypto` (market-priced) and `Property, Vehicle, OtherAsset` (manually valued). Liabilities and `Depository` are out of scope.

---

## File Structure

| File | Responsibility |
|---|---|
| `config/real_return/cpi.yml` | Real annual CPI index per area (CN/US/WLD), with `source`/`as_of`. |
| `config/real_return/benchmarks.yml` | Real annual series: sp500, csi300, gold, deposit, govbond, real_estate (CN/US). |
| `app/models/real_return/region.rb` | `RealReturn::Region` — currency→CPI/real-estate region map + benchmark key list. |
| `app/models/real_return/analysis.rb` | `RealReturn::Analysis` — per-account cashflow extraction + valuation resolution + metrics. |
| `app/models/real_return/portfolio_report.rb` | `RealReturn::PortfolioReport` — family-level aggregation + league table. |
| `app/models/account.rb` (modify) | add `#real_return`. |
| `app/models/family.rb` (modify) | add `#real_return_report`. |
| `test/models/real_return/{region,analysis,portfolio_report}_test.rb`, plus account/family test additions | Tests. |

---

## Task 1: Real reference data (`config/real_return/*.yml`)

**This task is controller-executed** (curated web fetch, not code transcription): the controller assembles real annual values from cited public sources and writes the two YAML files. The subagent step here only adds the **smoke test** that validates shape/sanity once the files exist. The files use integer year keys → float values, matching the Phase-1 reader.

**Required shape** (years ~2000–2025; `real_estate` is region-keyed):

```yaml
# config/real_return/cpi.yml
metadata:
  source: "FRED CPIAUCSL (US); national statistics (CN); world avg (WLD)"
  as_of: "2025-12-31"
CN: { 2000: 100.0, 2001: 100.7, ... }
US: { 2000: 100.0, 2001: 102.8, ... }
WLD: { 2000: 100.0, ... }
```
```yaml
# config/real_return/benchmarks.yml
metadata:
  source: "Public market data: year-end index levels / spot / reference rates"
  as_of: "2025-12-31"
sp500:       { 2000: 1320.28, ... }     # year-end index level (total-return proxy ok)
csi300:      { 2005: 1000.0, ... }       # CSI 300 launched 2005
gold:        { 2000: 273.6, ... }        # USD/oz year-end
deposit:     { 2000: 1.0, ... }          # cumulative growth index of a rolling 1y deposit
govbond:     { 2000: 1.0, ... }          # cumulative growth index of a 10y gov bond proxy
real_estate:
  US: { 2000: 100.0, ... }               # Case-Shiller / FHFA national index
  CN: { 2000: 100.0, ... }               # NBS 70-city composite (documented as approximate)
```

Notes the controller must honor when assembling:
- `metadata` is a reserved top-level key; the reader ignores it because lookups are by explicit area/key (`cpi_data["CN"]`, `benchmark_data["sp500"]`) — `metadata` is simply never requested. (No reader change needed.)
- `deposit`/`govbond` are stored as **cumulative growth indices** (start at 1.0, multiply by `(1+rate)` each year) so the Phase-1 `growth = level(to)/level(from)` works uniformly.
- For series that don't span the full range (e.g. `csi300` from 2005), only include years with real data; the reader returns `nil` before the earliest year, which the analysis handles gracefully.

- [ ] **Step 1 (controller): write the two data files** from cited public sources covering 2000–2025 (csi300 from 2005). Record provenance in each `metadata` block.

- [ ] **Step 2: write the smoke test.** Create `test/models/real_return/bundled_data_test.rb`:

```ruby
require "test_helper"

class RealReturn::BundledDataTest < ActiveSupport::TestCase
  setup { @data = RealReturn::ReferenceData::Bundled.new }  # default config/real_return paths

  test "cpi series load and are monotonic-ish and positive for CN and US" do
    %w[CN US].each do |area|
      range = @data.cpi_range(area: area)
      assert range, "missing CPI range for #{area}"
      v_start = @data.cpi_index(area: area, on: range.begin)
      v_end = @data.cpi_index(area: area, on: range.end)
      assert v_start.positive? && v_end.positive?, "#{area} CPI must be positive"
      assert v_end >= v_start, "#{area} CPI should rise over the full range"
    end
  end

  test "each benchmark key loads with a positive level at its latest year" do
    %w[sp500 csi300 gold deposit govbond].each do |key|
      range = @data.benchmark_range(key: key)
      assert range, "missing benchmark range for #{key}"
      assert @data.benchmark_level(key: key, on: range.end).positive?, "#{key} latest level must be positive"
    end
  end

  test "real_estate is region-keyed for CN and US" do
    assert @data.benchmark_level(key: "real_estate", on: Date.new(2015, 1, 1), region: "US")&.positive?
    assert @data.benchmark_level(key: "real_estate", on: Date.new(2015, 1, 1), region: "CN")&.positive?
  end
end
```

- [ ] **Step 3: run it** — `bin/rails test test/models/real_return/bundled_data_test.rb` → 3 runs, 0 failures.

- [ ] **Step 4: commit**

```bash
git add config/real_return/cpi.yml config/real_return/benchmarks.yml test/models/real_return/bundled_data_test.rb
git commit -m "feat(real_return): bundle real CPI and benchmark annual series

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: `RealReturn::Region`

**Files:** Create `app/models/real_return/region.rb`; Test `test/models/real_return/region_test.rb`

- [ ] **Step 1: failing test.** Create `test/models/real_return/region_test.rb`:

```ruby
require "test_helper"

class RealReturn::RegionTest < ActiveSupport::TestCase
  test "cpi_area maps known currencies and falls back to WLD" do
    assert_equal "CN", RealReturn::Region.cpi_area("CNY")
    assert_equal "US", RealReturn::Region.cpi_area("USD")
    assert_equal "WLD", RealReturn::Region.cpi_area("EUR")
  end

  test "real_estate region maps known currencies and falls back to US" do
    assert_equal "CN", RealReturn::Region.real_estate("CNY")
    assert_equal "US", RealReturn::Region.real_estate("JPY")
  end

  test "for_benchmark returns a region only for real_estate" do
    assert_equal "CN", RealReturn::Region.for_benchmark("real_estate", "CNY")
    assert_nil RealReturn::Region.for_benchmark("sp500", "CNY")
  end

  test "BENCHMARK_KEYS lists the six vehicles" do
    assert_equal %w[sp500 csi300 gold deposit govbond real_estate], RealReturn::Region::BENCHMARK_KEYS
  end
end
```

- [ ] **Step 2: run → fails** (`uninitialized constant RealReturn::Region`).

- [ ] **Step 3: implement.** Create `app/models/real_return/region.rb`:

```ruby
module RealReturn
  # Maps a family base currency to the CPI / real-estate region used for lookups,
  # and holds the canonical benchmark key list.
  module Region
    BY_CURRENCY = { "CNY" => "CN", "USD" => "US" }.freeze
    BENCHMARK_KEYS = %w[sp500 csi300 gold deposit govbond real_estate].freeze

    module_function

    def cpi_area(currency)
      BY_CURRENCY.fetch(currency, "WLD")
    end

    # real_estate data only exists for CN and US; default everything else to US.
    def real_estate(currency)
      BY_CURRENCY.fetch(currency, "US")
    end

    # Region argument for a benchmark lookup: only real_estate is region-keyed.
    def for_benchmark(key, currency)
      key == "real_estate" ? real_estate(currency) : nil
    end
  end
end
```

- [ ] **Step 4: run → passes** (4 runs, 0 failures).

- [ ] **Step 5: commit**

```bash
git add app/models/real_return/region.rb test/models/real_return/region_test.rb
git commit -m "feat(real_return): add Region currency->area mapping and benchmark keys

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: `RealReturn::Analysis` (per-account)

**Files:** Create `app/models/real_return/analysis.rb`; Test `test/models/real_return/analysis_test.rb`

- [ ] **Step 1: failing test.** Create `test/models/real_return/analysis_test.rb`:

```ruby
require "test_helper"

class RealReturn::AnalysisTest < ActiveSupport::TestCase
  include LedgerTestingHelper

  # Reference data with known synthetic series (from Phase 1 fixtures), so metric
  # assertions are deterministic. Series cover 2010..2012.
  def ref
    dir = Rails.root.join("test", "fixtures", "files", "real_return")
    RealReturn::ReferenceData::Bundled.new(
      cpi_path: dir.join("cpi.sample.yml"),
      benchmarks_path: dir.join("benchmarks.sample.yml")
    )
  end

  test "property with purchase and current valuation computes nominal CAGR" do
    account = create_account_with_ledger(
      account: { type: Property, currency: "CNY", balance: 0 },
      entries: [
        { type: "opening_anchor", date: Date.new(2010, 1, 1), balance: 1_000_000 },
        { type: "current_anchor", date: Date.new(2012, 1, 1), balance: 1_440_000 }
      ]
    )
    analysis = RealReturn::Analysis.new(account, as_of: Date.new(2012, 1, 1), base_currency: "CNY", reference_data: ref)

    assert_not analysis.estimated?
    # 1.0M -> 1.44M over 730 days => 1.44**(365/730) - 1 = 0.20
    assert_in_delta 0.20, analysis.nominal_return, 1e-3
    assert analysis.has_data?
  end

  test "property with only a purchase estimates current value from the house index" do
    # real_estate CN sample: 2010 -> 2012 grows 1.00 -> 1.21, so 1.0M -> ~1.21M
    account = create_account_with_ledger(
      account: { type: Property, currency: "CNY", balance: 0 },
      entries: [ { type: "opening_anchor", date: Date.new(2010, 1, 1), balance: 1_000_000 } ]
    )
    analysis = RealReturn::Analysis.new(account, as_of: Date.new(2012, 1, 1), base_currency: "CNY", reference_data: ref)

    assert analysis.estimated?
    # 1.21**(365/730) - 1 = 0.10
    assert_in_delta 0.10, analysis.nominal_return, 1e-3
  end

  test "investment account derives terminal from holdings and flows from trades" do
    account = create_account_with_ledger(
      account: { type: Investment, currency: "USD", balance: 0 },
      entries: [ { type: "trade", date: Date.new(2010, 1, 1), ticker: "ACME", qty: 10, price: 100 } ],
      holdings: [ { ticker: "ACME", date: Date.new(2012, 1, 1), qty: 10, price: 150, amount: 1500 } ]
    )
    analysis = RealReturn::Analysis.new(account, as_of: Date.new(2012, 1, 1), base_currency: "USD", reference_data: ref)

    # bought 1000, now worth 1500 over 730 days => 1.5**(365/730) - 1 = 0.2247
    assert_in_delta 0.2247, analysis.nominal_return, 1e-3
    assert_equal [ [ Date.new(2010, 1, 1), 1000.0 ] ], analysis.contributions
  end

  test "real_return and beats_inflation use CPI for the base currency" do
    account = create_account_with_ledger(
      account: { type: Property, currency: "CNY", balance: 0 },
      entries: [
        { type: "opening_anchor", date: Date.new(2010, 1, 1), balance: 1_000_000 },
        { type: "current_anchor", date: Date.new(2012, 1, 1), balance: 1_440_000 }
      ]
    )
    analysis = RealReturn::Analysis.new(account, as_of: Date.new(2012, 1, 1), base_currency: "CNY", reference_data: ref)

    # nominal ~0.20, CN inflation ~0.0488 => real ~ (1.20/1.0488)-1 ~= 0.1440
    assert_in_delta 0.144, analysis.real_return, 5e-3
    assert_equal true, analysis.beats_inflation?
  end

  test "benchmark_returns gives a counterfactual rate per key" do
    account = create_account_with_ledger(
      account: { type: Property, currency: "CNY", balance: 0 },
      entries: [
        { type: "opening_anchor", date: Date.new(2010, 1, 1), balance: 1_000_000 },
        { type: "current_anchor", date: Date.new(2012, 1, 1), balance: 1_440_000 }
      ]
    )
    analysis = RealReturn::Analysis.new(account, as_of: Date.new(2012, 1, 1), base_currency: "CNY", reference_data: ref)
    returns = analysis.benchmark_returns

    assert_equal RealReturn::Region::BENCHMARK_KEYS.sort, returns.keys.sort
    # sp500 sample 1.0 -> 1.5 => 0.2247 counterfactual on the single 2010 contribution
    assert_in_delta 0.2247, returns["sp500"], 1e-3
  end
end
```

- [ ] **Step 2: run → fails** (`uninitialized constant RealReturn::Analysis`).

- [ ] **Step 3: implement.** Create `app/models/real_return/analysis.rb`:

```ruby
module RealReturn
  # Per-account real-return analysis. Reads Maybe's ledger, normalizes to the base
  # currency, and answers nominal / real / benchmark questions via the Phase-1 POROs.
  class Analysis
    MARKET_PRICED = %w[Investment Crypto].freeze
    MANUAL_VALUED = %w[Property Vehicle OtherAsset].freeze
    IN_SCOPE = (MARKET_PRICED + MANUAL_VALUED).freeze

    attr_reader :account, :as_of, :base_currency

    def initialize(account, as_of: Date.current, base_currency: nil, reference_data: ReferenceData.default)
      @account = account
      @as_of = as_of
      @base_currency = base_currency || account.family.currency
      @reference_data = reference_data
      @cpi = Cpi.new(reference_data: reference_data)
      @benchmark = Benchmark.new(reference_data: reference_data)
    end

    def in_scope?
      IN_SCOPE.include?(account.accountable_type)
    end

    # Signed cashflows in base currency: [Date, Float]. Outflows negative, terminal positive.
    def flows
      @flows ||= build_flows.compact
    end

    # Contributions as positive [Date, Float] (money invested), for counterfactuals.
    def contributions
      flows.select { |(_, amt)| amt.negative? }.map { |(d, amt)| [ d, -amt ] }
    end

    def start_date
      contributions.map(&:first).min
    end

    def estimated?
      flows # ensure terminal computed (sets @estimated as a side effect)
      @estimated == true
    end

    def has_data?
      contributions.any? && (terminal_value&.positive? || false)
    end

    def nominal_return
      Xirr.compute(flows)
    end

    def real_return
      r = nominal_return
      return nil if r.nil? || start_date.nil?

      @cpi.real_return(nominal: r, area: cpi_area, from: start_date, to: as_of)
    end

    def beats_inflation?
      r = nominal_return
      return nil if r.nil? || start_date.nil?

      @cpi.beats_inflation?(nominal: r, area: cpi_area, from: start_date, to: as_of)
    end

    # { "sp500" => rate_or_nil, ... } counterfactual money-weighted returns.
    def benchmark_returns
      Region::BENCHMARK_KEYS.index_with do |key|
        @benchmark.counterfactual_return(
          contributions: contributions, key: key, as_of: as_of,
          region: Region.for_benchmark(key, base_currency)
        )
      end
    end

    def cpi_area
      Region.cpi_area(base_currency)
    end

    private
      def build_flows
        if MARKET_PRICED.include?(account.accountable_type)
          market_priced_flows
        else
          manual_valued_flows
        end
      end

      # Each trade is a signed cashflow (entry.amount = qty*price: buy +, sell -),
      # negated to the Xirr convention. Terminal = current holdings value.
      def market_priced_flows
        flows = account.entries.where(entryable_type: "Trade").map do |entry|
          amt = to_base(entry.amount, entry.currency, entry.date)
          amt && [ entry.date, -amt ]
        end
        tv = terminal_value
        flows << [ as_of, tv ] if tv&.positive?
        flows
      end

      # Opening valuation = purchase; terminal = latest valuation, else house-index estimate.
      def manual_valued_flows
        opening = valuations.first
        return [] if opening.nil?

        purchase = to_base(opening.amount, opening.currency, opening.date)
        tv = terminal_value
        return [] if purchase.nil? || purchase <= 0 || tv.nil? || tv <= 0

        [ [ opening.date, -purchase ], [ as_of, tv ] ]
      end

      def valuations
        @valuations ||= account.entries.where(entryable_type: "Valuation").order(:date).to_a
      end

      def terminal_value
        return @terminal_value if defined?(@terminal_value)

        @terminal_value = if MARKET_PRICED.include?(account.accountable_type)
          holdings_value
        else
          manual_terminal_value
        end
      end

      def holdings_value
        latest_date = account.holdings.maximum(:date)
        return nil if latest_date.nil?

        account.holdings.where(date: latest_date).sum(0.0) do |h|
          to_base(h.amount, h.currency, as_of) || 0.0
        end
      end

      def manual_terminal_value
        return nil if valuations.empty?

        if valuations.length >= 2
          latest = valuations.last
          to_base(latest.amount, latest.currency, latest.date)
        else
          estimate_from_index(valuations.first)
        end
      end

      # Estimate current value by scaling the purchase by the real-estate index (Property only).
      def estimate_from_index(opening)
        return nil unless account.accountable_type == "Property"

        purchase = to_base(opening.amount, opening.currency, opening.date)
        return nil if purchase.nil?

        g = @benchmark.growth(key: "real_estate", from: opening.date, to: as_of,
                              region: Region.real_estate(base_currency))
        return nil if g.nil?

        @estimated = true
        purchase * g
      end

      # Convert a Numeric amount in `currency` to a base-currency Float, or nil if no FX rate.
      def to_base(amount, currency, date)
        Money.new(amount, currency).exchange_to(base_currency, date: date).amount.to_f
      rescue Money::ConversionError
        nil
      end
  end
end
```

- [ ] **Step 4: run → passes** (6 runs, 0 failures). If an FX/`Money` issue arises for single-currency accounts, note that `exchange_to` returns `self` when currencies match (no rate needed) — single-currency tests need no `exchange_rates`.

- [ ] **Step 5: commit**

```bash
git add app/models/real_return/analysis.rb test/models/real_return/analysis_test.rb
git commit -m "feat(real_return): add per-account Analysis (cashflow extraction + metrics)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: `RealReturn::PortfolioReport` + entry points

**Files:** Create `app/models/real_return/portfolio_report.rb`; modify `app/models/account.rb`, `app/models/family.rb`; Test `test/models/real_return/portfolio_report_test.rb`

- [ ] **Step 1: failing test.** Create `test/models/real_return/portfolio_report_test.rb`:

```ruby
require "test_helper"

class RealReturn::PortfolioReportTest < ActiveSupport::TestCase
  include LedgerTestingHelper

  def ref
    dir = Rails.root.join("test", "fixtures", "files", "real_return")
    RealReturn::ReferenceData::Bundled.new(
      cpi_path: dir.join("cpi.sample.yml"),
      benchmarks_path: dir.join("benchmarks.sample.yml")
    )
  end

  test "aggregates in-scope asset accounts and ranks a league table" do
    family = families(:empty)
    family.update!(currency: "CNY")

    create_account_with_ledger(
      account: { type: Property, currency: "CNY", balance: 0 },
      entries: [
        { type: "opening_anchor", date: Date.new(2010, 1, 1), balance: 1_000_000 },
        { type: "current_anchor", date: Date.new(2012, 1, 1), balance: 1_440_000 }
      ]
    )

    report = RealReturn::PortfolioReport.new(family, as_of: Date.new(2012, 1, 1), reference_data: ref)

    assert report.analyses.one?
    assert_in_delta 0.20, report.nominal_return, 1e-3
    assert_equal "CN", report.cpi_area
    labels = report.league_table.map(&:first)
    assert_includes labels, "You"
    assert_includes labels, "sp500"
    assert_includes labels, "cpi"
    # league is ranked high -> low; the first row's value is the max present
    values = report.league_table.map(&:last).compact
    assert_equal values.max, report.league_table.first.last
  end
end
```

- [ ] **Step 2: run → fails** (`uninitialized constant RealReturn::PortfolioReport`).

- [ ] **Step 3: implement.** Create `app/models/real_return/portfolio_report.rb`:

```ruby
module RealReturn
  # Family-level rollup: merges all in-scope asset accounts' cashflows into one
  # schedule for portfolio money-weighted metrics, plus a benchmark league table.
  class PortfolioReport
    attr_reader :family, :as_of, :base_currency

    def initialize(family, as_of: Date.current, reference_data: ReferenceData.default)
      @family = family
      @as_of = as_of
      @base_currency = family.currency
      @reference_data = reference_data
      @cpi = Cpi.new(reference_data: reference_data)
      @benchmark = Benchmark.new(reference_data: reference_data)
    end

    def analyses
      @analyses ||= family.accounts.visible
        .where(accountable_type: Analysis::IN_SCOPE)
        .map { |account| Analysis.new(account, as_of: as_of, base_currency: base_currency, reference_data: @reference_data) }
        .select(&:has_data?)
    end

    # All accounts' signed cashflows merged (each account contributes its own terminal at as_of).
    def flows
      @flows ||= analyses.flat_map(&:flows)
    end

    def contributions
      flows.select { |(_, amt)| amt.negative? }.map { |(d, amt)| [ d, -amt ] }
    end

    def start_date
      contributions.map(&:first).min
    end

    def nominal_return
      Xirr.compute(flows)
    end

    def real_return
      r = nominal_return
      return nil if r.nil? || start_date.nil?

      @cpi.real_return(nominal: r, area: cpi_area, from: start_date, to: as_of)
    end

    def beats_inflation?
      r = nominal_return
      return nil if r.nil? || start_date.nil?

      @cpi.beats_inflation?(nominal: r, area: cpi_area, from: start_date, to: as_of)
    end

    # Ranked [label, annualized_or_nil]: your portfolio + each benchmark + a CPI row.
    def league_table
      rows = [ [ "You", nominal_return ] ]
      Region::BENCHMARK_KEYS.each do |key|
        rows << [ key, @benchmark.counterfactual_return(
          contributions: contributions, key: key, as_of: as_of,
          region: Region.for_benchmark(key, base_currency)
        ) ]
      end
      rows << [ "cpi", cpi_annualized ]
      Benchmark.rank(rows)
    end

    def cpi_area
      Region.cpi_area(base_currency)
    end

    private
      def cpi_annualized
        return nil if start_date.nil?

        @cpi.annualized(area: cpi_area, from: start_date, to: as_of)
      end
  end
end
```

- [ ] **Step 4: add entry points.** In `app/models/account.rb`, add this method inside the `class Account` body (after the existing public instance methods, before any `private`):

```ruby
  def real_return(as_of: Date.current)
    RealReturn::Analysis.new(self, as_of: as_of)
  end
```

In `app/models/family.rb`, add this method inside the `class Family` body:

```ruby
  def real_return_report(as_of: Date.current)
    RealReturn::PortfolioReport.new(self, as_of: as_of)
  end
```

- [ ] **Step 5: extend the test** to cover the entry points. Append these tests inside `RealReturn::PortfolioReportTest` (before its final `end`):

```ruby
  test "Account#real_return returns an Analysis" do
    account = create_account_with_ledger(
      account: { type: Property, currency: "USD", balance: 0 },
      entries: [ { type: "opening_anchor", date: Date.new(2010, 1, 1), balance: 1000 } ]
    )
    assert_instance_of RealReturn::Analysis, account.real_return(as_of: Date.new(2012, 1, 1))
  end

  test "Family#real_return_report returns a PortfolioReport" do
    assert_instance_of RealReturn::PortfolioReport, families(:empty).real_return_report
  end
```

- [ ] **Step 6: run → passes** (3 runs, 0 failures): `bin/rails test test/models/real_return/portfolio_report_test.rb`

- [ ] **Step 7: run the whole suite + rubocop.**

```bash
bin/rails test test/models/real_return/
bin/rubocop app/models/real_return/ app/models/account.rb app/models/family.rb test/models/real_return/
```
Expected: all green, no offenses.

- [ ] **Step 8: commit**

```bash
git add app/models/real_return/portfolio_report.rb app/models/account.rb app/models/family.rb test/models/real_return/portfolio_report_test.rb
git commit -m "feat(real_return): add PortfolioReport and Account/Family entry points

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Done criteria for Phase 2

- `bin/rails test test/models/real_return/` passes (all files).
- Real CPI/benchmark data bundled and loaded by the default `ReferenceData::Bundled`.
- `account.real_return` and `family.real_return_report` return populated objects; property current-value falls back to the house-index estimate (flagged `estimated?`).
- Multi-currency legs convert via `Money#exchange_to` (missing-rate legs drop rather than crash).

**Next:** Phase 3 (UI) — `resource :real_return` route + `RealReturnsController#show`, the three-zone page (portfolio overview card with net-worth-vs-CPI chart, per-asset scorecard table, benchmark league table), ViewComponents, and the nav link. Written after Phase 2 lands and is verified.
