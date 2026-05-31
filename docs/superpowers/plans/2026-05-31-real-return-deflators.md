# RealReturn Deflators (P-0) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let "real return" be measured against three inflation lenses — consumer (CPI), monetary (M2), and asset (house price) — and show all three on the existing Returns page.

**Architecture:** A pure-Ruby `RealReturn::Deflator` unifies the three lenses (each is a level series whose annualized growth is the "inflation" rate; real return via Fisher). It reads the bundled `cpi.yml`, the new `m2.yml` (already fetched, real World Bank data), and the `real_estate` series in `benchmarks.yml`, all through `ReferenceData` (extended with an `m2_index` reader). `PortfolioReport` exposes `real_returns_by_lens`; the Returns view shows the three figures.

**Tech Stack:** Ruby 3.4.4 / Rails 7.2, Minitest + fixtures, existing `RealReturn::{ReferenceData, Region, Cpi}` engine, Tailwind/ERB.

**Depends on:** the shipped RealReturn engine + data on branch `feature/real-return` (`config/real_return/{cpi,m2,benchmarks}.yml` all present and real).

**Conventions:** Run from `/Users/clintongao/coding/maybe`; if `ruby -v` ≠ 3.4.4 prefix `export PATH="$HOME/.rbenv/shims:$PATH"; `. Tests: `bin/rails test <path>`. Functional Tailwind tokens only; `icon` helper. Don't run `bin/rails server` (use Claude_Preview for the browser step).

---

## File Structure

| File | Responsibility |
|---|---|
| `app/models/real_return/reference_data/bundled.rb` (modify) | add `m2_index(area:, on:)` + `m2_range(area:)` (mirror `cpi_index`); add `m2_path:` arg |
| `app/models/real_return/deflator.rb` (create) | `RealReturn::Deflator` — CPI/M2/house-price annualized inflation + real return |
| `app/models/real_return/portfolio_report.rb` (modify) | add `#real_returns_by_lens` |
| `app/helpers/real_returns_helper.rb` (modify) | add lens labels + `rr_lens_label` |
| `app/views/real_returns/show.html.erb` (modify) | overview card shows real return vs CPI / M2 / house price |
| `test/fixtures/files/real_return/m2.sample.yml` (create) | synthetic M2 series for tests |
| `test/models/real_return/{reference_data_bundled,deflator}_test.rb` | tests (bundled gets a new test; deflator is new) |

---

## Task 1: `ReferenceData::Bundled#m2_index`

**Files:**
- Modify: `app/models/real_return/reference_data/bundled.rb`
- Create: `test/fixtures/files/real_return/m2.sample.yml`
- Test: `test/models/real_return/reference_data_bundled_test.rb` (append one test)

- [ ] **Step 1: Create the synthetic M2 fixture.** Create `test/fixtures/files/real_return/m2.sample.yml`:

```yaml
CN:
  2010: 100.0
  2011: 110.0
  2012: 121.0
US:
  2010: 100.0
  2011: 105.0
```

- [ ] **Step 2: Write the failing test.** Append this test inside `class RealReturn::ReferenceData::BundledTest` in `test/models/real_return/reference_data_bundled_test.rb`, before its final `end`. Also update the `setup` block to pass `m2_path` (replace the existing `@data = RealReturn::ReferenceData::Bundled.new(...)` call in `setup` with the version below that adds `m2_path:`):

```ruby
  # (in setup) — add m2_path so m2_index can be tested:
  #   @data = RealReturn::ReferenceData::Bundled.new(
  #     cpi_path: dir.join("cpi.sample.yml"),
  #     benchmarks_path: dir.join("benchmarks.sample.yml"),
  #     m2_path: dir.join("m2.sample.yml")
  #   )

  test "m2_index reads the M2 series and interpolates" do
    assert_in_delta 110.0, @data.m2_index(area: "CN", on: Date.new(2011, 1, 1)), 1e-9
    assert_equal (Date.new(2010, 1, 1)..Date.new(2012, 1, 1)), @data.m2_range(area: "CN")
    assert_nil @data.m2_index(area: "ZZ", on: Date.new(2011, 1, 1))
  end
```

Concretely, the `setup` block should read:

```ruby
  setup do
    dir = Rails.root.join("test", "fixtures", "files", "real_return")
    @data = RealReturn::ReferenceData::Bundled.new(
      cpi_path: dir.join("cpi.sample.yml"),
      benchmarks_path: dir.join("benchmarks.sample.yml"),
      m2_path: dir.join("m2.sample.yml")
    )
  end
```

- [ ] **Step 3: Run it → fails** (`unknown keyword: :m2_path` or `NoMethodError: m2_index`): `bin/rails test test/models/real_return/reference_data_bundled_test.rb`

- [ ] **Step 4: Implement.** In `app/models/real_return/reference_data/bundled.rb`:

(a) Add the default path constant after `DEFAULT_BENCHMARKS_PATH`:

```ruby
      DEFAULT_M2_PATH = Rails.root.join("config", "real_return", "m2.yml")
```

(b) Replace the `initialize` method with one that accepts `m2_path:`:

```ruby
      def initialize(cpi_path: DEFAULT_CPI_PATH, benchmarks_path: DEFAULT_BENCHMARKS_PATH, m2_path: DEFAULT_M2_PATH)
        @cpi_path = cpi_path
        @benchmarks_path = benchmarks_path
        @m2_path = m2_path
      end
```

(c) Add the two public reader methods (place them right after `benchmark_range`):

```ruby
      def m2_index(area:, on:)
        interpolate(m2_series(area), on)
      end

      def m2_range(area:)
        series_range(m2_series(area))
      end
```

(d) Add the private series loader (place it next to `cpi_data`/`cpi_series` in the `private` section):

```ruby
        def m2_data
          @m2_data ||= load_yaml(@m2_path)
        end

        def m2_series(area)
          raw = m2_data[area.to_s]
          raw && normalize_years(raw)
        end
```

- [ ] **Step 5: Run it → passes** (existing tests + the new one, 0 failures): `bin/rails test test/models/real_return/reference_data_bundled_test.rb`

- [ ] **Step 6: Commit**

```bash
git add app/models/real_return/reference_data/bundled.rb \
        test/fixtures/files/real_return/m2.sample.yml \
        test/models/real_return/reference_data_bundled_test.rb
git commit -m "feat(real_return): add m2_index reader to bundled reference data

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: `RealReturn::Deflator`

**Files:**
- Create: `app/models/real_return/deflator.rb`
- Test: `test/models/real_return/deflator_test.rb`

- [ ] **Step 1: Write the failing test.** Create `test/models/real_return/deflator_test.rb`:

```ruby
require "test_helper"

class RealReturn::DeflatorTest < ActiveSupport::TestCase
  def ref
    dir = Rails.root.join("test", "fixtures", "files", "real_return")
    RealReturn::ReferenceData::Bundled.new(
      cpi_path: dir.join("cpi.sample.yml"),
      benchmarks_path: dir.join("benchmarks.sample.yml"),
      m2_path: dir.join("m2.sample.yml")
    )
  end

  def deflator
    RealReturn::Deflator.new(currency: "CNY", reference_data: ref)
  end

  test "cpi lens annualizes the CPI series" do
    # CN CPI 100 -> 110 over 730 days => 1.1**(365/730) - 1 ~= 0.04881
    rate = deflator.annualized(lens: :cpi, from: Date.new(2010, 1, 1), to: Date.new(2012, 1, 1))
    assert_in_delta 0.04881, rate, 1e-4
  end

  test "m2 lens annualizes the M2 series" do
    # CN M2 100 -> 121 over 730 days => 1.21**(365/730) - 1 = 0.10
    rate = deflator.annualized(lens: :m2, from: Date.new(2010, 1, 1), to: Date.new(2012, 1, 1))
    assert_in_delta 0.10, rate, 1e-4
  end

  test "house_price lens annualizes the real_estate series for the currency's region" do
    # real_estate CN sample 1.00 -> 1.21 over 730 days => 0.10
    rate = deflator.annualized(lens: :house_price, from: Date.new(2010, 1, 1), to: Date.new(2012, 1, 1))
    assert_in_delta 0.10, rate, 1e-4
  end

  test "real_return deflates the nominal rate by the chosen lens" do
    # nominal 0.10 vs M2 inflation 0.10 => real ~ 0
    real = deflator.real_return(nominal: 0.10, lens: :m2, from: Date.new(2010, 1, 1), to: Date.new(2012, 1, 1))
    assert_in_delta 0.0, real, 1e-4
  end

  test "returns nil when the lens series is unavailable" do
    # USD M2 sample only has 2010-2011; ask outside / WLD area has no M2
    usd = RealReturn::Deflator.new(currency: "EUR", reference_data: ref) # EUR -> cpi_area WLD (no M2)
    assert_nil usd.annualized(lens: :m2, from: Date.new(2010, 1, 1), to: Date.new(2012, 1, 1))
  end

  test "LENSES lists the three deflators" do
    assert_equal %i[cpi m2 house_price], RealReturn::Deflator::LENSES
  end
end
```

- [ ] **Step 2: Run it → fails** (`uninitialized constant RealReturn::Deflator`): `bin/rails test test/models/real_return/deflator_test.rb`

- [ ] **Step 3: Implement.** Create `app/models/real_return/deflator.rb`:

```ruby
module RealReturn
  # Measures "real" return against one of three inflation lenses:
  #   :cpi         consumer prices (cost of living)
  #   :m2          broad money growth (your share of total money)
  #   :house_price the regional home-price index (asset inflation)
  # Each lens is a level series; its annualized growth is the inflation rate,
  # and real return follows the Fisher equation.
  class Deflator
    LENSES = %i[cpi m2 house_price].freeze

    def initialize(currency:, reference_data: ReferenceData.default)
      @currency = currency
      @reference_data = reference_data
    end

    # Annualized inflation (Actual/365) under `lens` over [from, to]. nil if unavailable.
    def annualized(lens:, from:, to:)
      v0, v1 = endpoints(lens, from, to)
      days = (to - from).to_i
      return nil if v0.nil? || v1.nil? || v0 <= 0 || days <= 0

      (v1 / v0)**(365.0 / days) - 1.0
    end

    # Inflation-adjusted real return under `lens` (Fisher). nil if unavailable.
    def real_return(nominal:, lens:, from:, to:)
      rate = annualized(lens: lens, from: from, to: to)
      return nil if rate.nil?

      (1.0 + nominal) / (1.0 + rate) - 1.0
    end

    private
      def endpoints(lens, from, to)
        case lens
        when :cpi
          area = Region.cpi_area(@currency)
          [ @reference_data.cpi_index(area: area, on: from), @reference_data.cpi_index(area: area, on: to) ]
        when :m2
          area = Region.cpi_area(@currency)
          [ @reference_data.m2_index(area: area, on: from), @reference_data.m2_index(area: area, on: to) ]
        when :house_price
          region = Region.real_estate(@currency)
          [ @reference_data.benchmark_level(key: "real_estate", on: from, region: region),
            @reference_data.benchmark_level(key: "real_estate", on: to, region: region) ]
        else
          [ nil, nil ]
        end
      end
  end
end
```

- [ ] **Step 4: Run it → passes** (6 runs, 0 failures): `bin/rails test test/models/real_return/deflator_test.rb`

- [ ] **Step 5: Commit**

```bash
git add app/models/real_return/deflator.rb test/models/real_return/deflator_test.rb
git commit -m "feat(real_return): add Deflator (CPI / M2 / house-price lenses)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: `PortfolioReport#real_returns_by_lens` + helper labels

**Files:**
- Modify: `app/models/real_return/portfolio_report.rb`, `app/helpers/real_returns_helper.rb`
- Test: `test/models/real_return/portfolio_report_test.rb` (append one test)

- [ ] **Step 1: Write the failing test.** Append inside `class RealReturn::PortfolioReportTest` (before its final `end`) in `test/models/real_return/portfolio_report_test.rb`:

```ruby
  test "real_returns_by_lens returns a real return per deflator lens" do
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

    by_lens = report.real_returns_by_lens
    assert_equal RealReturn::Deflator::LENSES, by_lens.keys
    # cpi lens must equal the existing real_return (both deflate by CN CPI)
    assert_in_delta report.real_return, by_lens[:cpi], 1e-9
  end
```

(`ref` is already defined as a helper method in this test file from earlier tasks.)

- [ ] **Step 2: Run it → fails** (`NoMethodError: real_returns_by_lens`): `bin/rails test test/models/real_return/portfolio_report_test.rb`

- [ ] **Step 3: Implement.** In `app/models/real_return/portfolio_report.rb`, add this public method right after the existing `beats_inflation?` method:

```ruby
    # { cpi: rate_or_nil, m2: rate_or_nil, house_price: rate_or_nil } — the portfolio's
    # real return under each inflation lens (consumer / monetary / asset).
    def real_returns_by_lens
      r = nominal_return
      return Deflator::LENSES.index_with { nil } if r.nil? || start_date.nil?

      deflator = Deflator.new(currency: base_currency, reference_data: @reference_data)
      Deflator::LENSES.index_with do |lens|
        deflator.real_return(nominal: r, lens: lens, from: start_date, to: as_of)
      end
    end
```

- [ ] **Step 4: Add helper labels.** In `app/helpers/real_returns_helper.rb`, add this constant + method inside the module (after `BENCHMARK_LABELS`):

```ruby
  LENS_LABELS = {
    cpi: "vs CPI (consumer)",
    m2: "vs M2 (money supply)",
    house_price: "vs house prices"
  }.freeze

  def rr_lens_label(lens)
    LENS_LABELS.fetch(lens.to_sym, lens.to_s)
  end
```

- [ ] **Step 5: Run it → passes**: `bin/rails test test/models/real_return/portfolio_report_test.rb`

- [ ] **Step 6: Commit**

```bash
git add app/models/real_return/portfolio_report.rb app/helpers/real_returns_helper.rb test/models/real_return/portfolio_report_test.rb
git commit -m "feat(real_return): PortfolioReport#real_returns_by_lens + lens labels

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: Show the three lenses on the Returns page

**Files:**
- Modify: `app/views/real_returns/show.html.erb`

- [ ] **Step 1: Add the three-lens row to the overview card.** In `app/views/real_returns/show.html.erb`, find this block (inside the portfolio overview card):

```erb
        <p class="text-sm text-secondary mt-1">
          Nominal <%= rr_pct_yr(@report.nominal_return) %> · Inflation <%= rr_pct_yr(@report.inflation_rate) %>
        </p>
```

Insert immediately AFTER that `</p>` (still inside the same `<div>`):

```erb
        <div class="mt-3 flex flex-wrap gap-x-6 gap-y-1 text-sm">
          <% @report.real_returns_by_lens.each do |lens, rate| %>
            <span class="text-secondary">
              <%= rr_lens_label(lens) %>:
              <span class="font-medium <%= rate.to_f >= 0 ? "text-success" : "text-destructive" %>"><%= rr_pct_yr(rate) %></span>
            </span>
          <% end %>
        </div>
```

- [ ] **Step 2: Verify the page still renders** (the controller test exercises the template): `bin/rails test test/controllers/real_returns_controller_test.rb` → 1 run, 0 failures. If it errors with a template/NoMethod error, STOP and report BLOCKED with the full error.

- [ ] **Step 3: Lint the view:** `bundle exec erb_lint app/views/real_returns/show.html.erb -a` → ends clean.

- [ ] **Step 4: Run the whole real_return suite + rubocop:**

```bash
bin/rails test test/models/real_return/ test/controllers/real_returns_controller_test.rb
bin/rubocop app/models/real_return/ app/helpers/real_returns_helper.rb
```
Expected: all green; no offenses.

- [ ] **Step 5: Commit**

```bash
git add app/views/real_returns/show.html.erb
git commit -m "feat(real_return): show real return vs CPI / M2 / house price on Returns page

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: Browser verification (controller-executed, Claude_Preview)

Not a subagent task — the controller runs this with the Claude_Preview MCP (`maybe` launch config).

- [ ] **Step 1:** `bin/rails tailwindcss:build`.
- [ ] **Step 2:** `preview_start` (name `maybe`); sign in as `admin@maybe.local` / `password` (the CNY family with real assets). Login tip: set the email/password inputs' values via the native setter + `input` event, then call `form.submit()` (a plain JS `.submit()` follows the 302; `requestSubmit` did not work reliably).
- [ ] **Step 3:** Navigate to `/real_return`. Screenshot. Confirm the overview card shows three figures: **vs CPI (consumer) ≈ +3.7%/yr · vs M2 (money supply) ≈ −3.4%/yr · vs house prices ≈ +3.8%/yr** (M2 negative, the others positive). Check `preview_console_logs` for errors.
- [ ] **Step 4:** If broken, fix view/helper/model, rebuild CSS, reload, re-screenshot.
- [ ] **Step 5:** Stop the preview server.

---

## Done criteria

- `bin/rails test test/models/real_return/ test/controllers/real_returns_controller_test.rb` passes.
- `/real_return` overview shows real return under all three lenses (CPI / M2 / house price), with M2 visibly different (negative for the demo CNY portfolio).
- erb_lint + rubocop clean on touched files.

**Next (after P-0):** P-A (CMA core) → P-B (Monte Carlo + Projection) → P-C (wealth tier) → P-D (projection UI), per the projections spec.
