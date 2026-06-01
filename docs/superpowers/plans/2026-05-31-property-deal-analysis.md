# Property Deal Analysis Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A standalone `/property_analysis` page that computes + visualizes a per-property cash-flow pro forma and a levered, real-terms, regime-aware Monte Carlo of equity value, reusing the `real_return` engine.

**Architecture:** A new `RealReturn::PropertyAnalysis` PORO does the property math (cash flow + levered real MC; nominal debt deflated by inflation; regime/glide/valuation drive the real price path). A singleton `PropertyAnalysisController#show` (like `ProjectionsController`) reads form params, defaults from the `real_estate_<region>` CMA, and renders. The portfolio Projection page is untouched.

**Tech Stack:** Rails 7 (Ruby), Minitest + fixtures, ERB, TailwindCSS, Hotwire; reuses `RealReturn::Cma`, `projection_fan_svg`, `rr_money`/`rr_pct_yr`/`projection_signed_pct`.

**Spec:** `docs/superpowers/specs/2026-05-31-property-deal-analysis-design.md`

**Commit policy:** Repo `CLAUDE.md` — commit only when the user asks. Commit steps included; confirm or get blanket approval. All messages end with the `Co-Authored-By` trailer.

**Conventions:** all rates are decimals (0.05 = 5%); `ltv`/`opex_pct`/`vacancy_pct` are fractions. Real terms throughout; debt is nominal (deflated by `inflation`). Standalone calculator — `Property` accounts have no rent/financing, so inputs come from the form.

---

### Task 1: `RealReturn::PropertyAnalysis#cash_flow`

**Files:**
- Create: `app/models/real_return/property_analysis.rb`
- Test: `test/models/real_return/property_analysis_test.rb`

- [ ] **Step 1: Write the failing test**

Create `test/models/real_return/property_analysis_test.rb`:

```ruby
require "test_helper"

class RealReturn::PropertyAnalysisTest < ActiveSupport::TestCase
  def build(**overrides)
    defaults = {
      price: 1_000_000.0, monthly_rent: 3_000.0, holding_years: 30, ltv: 0.6,
      mortgage_rate: 0.05, amortization_years: 30, opex_pct: 0.25, vacancy_pct: 0.05,
      real_rent_growth: 0.0, price_to_rent_current: 1.0, price_to_rent_target: 1.0,
      inflation: 0.02, sigma: 0.09, regimes: {}, regime_offsets: {}, paths: 800, seed: 9
    }
    RealReturn::PropertyAnalysis.new(**defaults.merge(overrides))
  end

  test "cash_flow computes the year-1 pro forma" do
    cf = build.cash_flow
    assert_in_delta 36_000.0, cf[:annual_rent], 1e-6
    assert_in_delta 0.036, cf[:gross_yield], 1e-9
    assert_in_delta 25_200.0, cf[:noi], 1e-6           # 36000 * (1 - 0.05 - 0.25)
    assert_in_delta 0.0252, cf[:cap_rate], 1e-9
    assert_in_delta 400_000.0, cf[:down_payment], 1e-6 # price - 0.6*price
    # amortizing payment 600000 @ 5% / 30y
    assert_in_delta 39_031.6, cf[:debt_service], 1.0
    assert_in_delta cf[:noi] / cf[:debt_service], cf[:dscr], 1e-9
    assert_in_delta (cf[:noi] - cf[:debt_service]) / cf[:down_payment], cf[:cash_on_cash], 1e-9
    assert_in_delta 0.25 + cf[:debt_service] / cf[:annual_rent], cf[:break_even_occupancy], 1e-9
  end

  test "cash_flow with no leverage: zero debt service, nil dscr, cash-on-cash == cap rate" do
    cf = build(ltv: 0.0).cash_flow
    assert_equal 0.0, cf[:debt_service]
    assert_nil cf[:dscr]
    assert_in_delta cf[:cap_rate], cf[:cash_on_cash], 1e-9   # down == price, ds == 0
  end
```

- [ ] **Step 2: Run to verify it fails**

Run: `bin/rails test test/models/real_return/property_analysis_test.rb`
Expected: FAIL — uninitialized constant `RealReturn::PropertyAnalysis`.

- [ ] **Step 3: Create the model with `initialize`, `cash_flow`, `debt_service`**

Create `app/models/real_return/property_analysis.rb`:

```ruby
module RealReturn
  # Per-property deal analysis: a year-1 cash-flow pro forma + a levered, real-terms Monte Carlo of
  # equity value reusing the regime/glide/valuation engine. Standalone (not tied to an Account).
  # Rates are decimals (0.05 = 5%); ltv/opex_pct/vacancy_pct are fractions. Real terms; debt nominal.
  class PropertyAnalysis
    def initialize(price:, monthly_rent:, holding_years:, ltv:, mortgage_rate:, amortization_years:,
                   opex_pct:, vacancy_pct:, real_rent_growth:, price_to_rent_current:,
                   price_to_rent_target:, inflation:, sigma:, real_rent_growth_end: nil,
                   regimes: {}, regime_offsets: {}, paths: 5000, seed: 123_456)
      @price = price.to_f
      @monthly_rent = monthly_rent.to_f
      @holding_years = holding_years.to_i
      @ltv = ltv.to_f
      @mortgage_rate = mortgage_rate.to_f
      @amortization_years = amortization_years.to_i
      @opex_pct = opex_pct.to_f
      @vacancy_pct = vacancy_pct.to_f
      @real_rent_growth = real_rent_growth.to_f
      @real_rent_growth_end = (real_rent_growth_end || real_rent_growth).to_f
      @price_to_rent_current = price_to_rent_current.to_f
      @price_to_rent_target = price_to_rent_target.to_f
      @inflation = inflation.to_f
      @sigma = sigma.to_f
      @regimes = regimes || {}
      @regime_offsets = regime_offsets || {}
      @paths = paths
      @seed = seed
    end

    # Year-1 pro forma (real terms). Returns a Hash.
    def cash_flow
      annual_rent = @monthly_rent * 12.0
      noi = annual_rent * (1.0 - @vacancy_pct - @opex_pct)
      loan = @price * @ltv
      down = @price - loan
      ds = debt_service(loan)
      {
        annual_rent: annual_rent,
        gross_yield: @price.zero? ? 0.0 : annual_rent / @price,
        noi: noi,
        cap_rate: @price.zero? ? 0.0 : noi / @price,
        loan: loan,
        down_payment: down,
        debt_service: ds,
        cash_on_cash: down.positive? ? (noi - ds) / down : nil,
        dscr: ds.zero? ? nil : noi / ds,
        break_even_occupancy: annual_rent.zero? ? nil : @opex_pct + ds / annual_rent
      }
    end

    private
      # Annual fixed-rate amortizing payment on `loan` (nominal). 0 if no loan/term.
      def debt_service(loan)
        return 0.0 if loan <= 0 || @amortization_years <= 0
        return loan / @amortization_years if @mortgage_rate <= 0

        r = @mortgage_rate
        loan * r / (1.0 - (1.0 + r)**(-@amortization_years))
      end
  end
end
```

- [ ] **Step 4: Run to verify it passes**

Run: `bin/rails test test/models/real_return/property_analysis_test.rb`
Expected: PASS (both tests).

- [ ] **Step 5: Commit**

```bash
git add app/models/real_return/property_analysis.rb test/models/real_return/property_analysis_test.rb
git commit -m "$(cat <<'EOF'
feat(real_return): PropertyAnalysis#cash_flow — per-property year-1 pro forma

Gross/net yield, NOI, cap rate, levered cash-on-cash, DSCR, break-even occupancy.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: `RealReturn::PropertyAnalysis#distribution` (levered real Monte Carlo)

**Files:**
- Modify: `app/models/real_return/property_analysis.rb`
- Test: `test/models/real_return/property_analysis_test.rb`

- [ ] **Step 1: Write the failing tests**

Append to `test/models/real_return/property_analysis_test.rb` (inside the class):

```ruby
  test "distribution percentiles are ordered and reproducible" do
    d = build(paths: 1500).distribution
    t = d[:terminal]
    assert_operator t[:p10], :<=, t[:p50]
    assert_operator t[:p50], :<=, t[:p90]
    assert_equal d[:years].size, d[:p50].size
    # reproducible for a fixed seed
    assert_in_delta d[:p50].last, build(paths: 1500).distribution[:p50].last, 1e-6
  end

  test "higher leverage widens the band and raises the ruin probability" do
    low = build(ltv: 0.2, paths: 2000).distribution
    high = build(ltv: 0.8, paths: 2000).distribution
    spread = ->(d) { d[:terminal][:p90] - d[:terminal][:p10] }
    assert_operator spread.call(high), :>, spread.call(low)
    assert_operator high[:negative_equity_share], :>=, low[:negative_equity_share]
  end

  test "a valuation de-rating lowers the median terminal equity" do
    flat = build(price_to_rent_current: 1.0, price_to_rent_target: 1.0, ltv: 0.0, paths: 2000).distribution
    derate = build(price_to_rent_current: 1.3, price_to_rent_target: 1.0, ltv: 0.0, paths: 2000).distribution
    assert_operator derate[:terminal][:p50], :<, flat[:terminal][:p50]
  end

  test "distribution exposes a multi-horizon table for years <= holding period" do
    d = build(holding_years: 10).distribution
    assert_equal [ 5, 10 ], d[:table].map { |row| row[:years] }
  end
```

- [ ] **Step 2: Run to verify they fail**

Run: `bin/rails test test/models/real_return/property_analysis_test.rb`
Expected: FAIL — `undefined method 'distribution'`.

- [ ] **Step 3: Implement `distribution` + its private helpers**

In `app/models/real_return/property_analysis.rb`, add the public `distribution` method (after `cash_flow`) and the private helpers (after `debt_service`):

```ruby
    # Levered real equity over the holding period: percentile bands per year (p10..p90) + terminal
    # stats, annualized levered real return percentiles, ruin probability, and a 5/10/20/30y table.
    def distribution
      n = @holding_years
      regimes = @regimes.to_a
      rng = Random.new(@seed)
      loan = @price * @ltv
      down = @price - loan
      ds_nominal = debt_service(loan)
      noi0 = cash_flow[:noi]
      val_amort = valuation_amort(n)

      by_year = Array.new(n + 1) { [] }
      @paths.times do
        regime = pick_regime(rng, regimes)
        off = regime ? (@regime_offsets[regime] || 0.0).to_f : 0.0
        value = @price
        noi = noi0
        cum_cash = 0.0
        by_year[0] << down
        (1..n).each do |t|
          g = lerp(@real_rent_growth, @real_rent_growth_end, t.to_f / n)
          mean_a = g + val_amort + off
          mean_a = -0.99 if mean_a < -0.99
          drift = Math.log(1.0 + mean_a) - 0.5 * @sigma**2
          value *= Math.exp(drift + @sigma * gaussian(rng))
          noi *= (1.0 + g)
          deflator = (1.0 + @inflation)**t
          cum_cash += noi - ds_nominal / deflator
          by_year[t] << value - nominal_balance(loan, t) / deflator + cum_cash
        end
      end

      terminal = by_year[n]
      ann = ->(equity) { (down <= 0 || equity <= 0) ? nil : (equity / down)**(1.0 / n) - 1.0 }
      {
        years: (0..n).to_a,
        p10: by_year.map { |v| percentile(v, 10) },
        p25: by_year.map { |v| percentile(v, 25) },
        p50: by_year.map { |v| percentile(v, 50) },
        p75: by_year.map { |v| percentile(v, 75) },
        p90: by_year.map { |v| percentile(v, 90) },
        terminal: { p10: percentile(terminal, 10), p50: percentile(terminal, 50), p90: percentile(terminal, 90) },
        annualized: { p10: ann.call(percentile(terminal, 10)), p50: ann.call(percentile(terminal, 50)),
                      p90: ann.call(percentile(terminal, 90)) },
        negative_equity_share: terminal.count { |e| e <= 0 }.to_f / @paths,
        table: [ 5, 10, 20, 30 ].select { |y| y <= n }.map do |y|
          { years: y, p10: percentile(by_year[y], 10), p50: percentile(by_year[y], 50), p90: percentile(by_year[y], 90) }
        end
      }
    end

    private
      def valuation_amort(n)
        return 0.0 unless @price_to_rent_current.positive? && @price_to_rent_target.positive?

        (@price_to_rent_target / @price_to_rent_current)**(1.0 / n) - 1.0
      end

      def lerp(a, b, frac)
        a + (b - a) * frac
      end

      # Remaining nominal loan balance after t annual payments (clamped >= 0).
      def nominal_balance(loan, t)
        return 0.0 if loan <= 0 || @amortization_years <= 0

        pay = debt_service(loan)
        bal =
          if @mortgage_rate <= 0
            loan - pay * t
          else
            r = @mortgage_rate
            loan * (1.0 + r)**t - pay * ((1.0 + r)**t - 1.0) / r
          end
        [ bal, 0.0 ].max
      end

      def gaussian(rng)
        u1 = rng.rand
        u1 = 1e-12 if u1 <= 0.0
        Math.sqrt(-2.0 * Math.log(u1)) * Math.cos(2.0 * Math::PI * rng.rand)
      end

      def pick_regime(rng, regimes)
        return nil if regimes.empty?

        u = rng.rand
        cum = 0.0
        regimes.each { |name, p| cum += p.to_f; return name if u < cum }
        regimes.last[0]
      end

      def percentile(values, pct)
        sorted = values.sort
        sorted[((pct / 100.0) * (sorted.size - 1)).round]
      end
```

(NOTE: `gaussian`/`pick_regime` are intentionally local copies of the `MonteCarlo` helpers — keeping `PropertyAnalysis` self-contained avoids touching the tested portfolio simulator. A shared `RealReturn::Sampling` module is a reasonable later cleanup, not part of v1.)

- [ ] **Step 4: Run to verify they pass**

Run: `bin/rails test test/models/real_return/property_analysis_test.rb`
Expected: PASS (all 6 tests).

- [ ] **Step 5: Commit**

```bash
git add app/models/real_return/property_analysis.rb test/models/real_return/property_analysis_test.rb
git commit -m "$(cat <<'EOF'
feat(real_return): PropertyAnalysis#distribution — levered real Monte Carlo

Real price path (regime/glide/valuation), nominal debt deflated by inflation,
levered-equity percentiles + annualized return + ruin probability + horizon table.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Route + `PropertyAnalysisController`

**Files:**
- Modify: `config/routes.rb`
- Create: `app/controllers/property_analysis_controller.rb`
- Test: `test/controllers/property_analysis_controller_test.rb`

- [ ] **Step 1: Add the route**

In `config/routes.rb`, immediately after the line `resource :projection, only: :show`, add:

```ruby
  resource :property_analysis, only: :show
```

- [ ] **Step 2: Write the failing controller test**

Create `test/controllers/property_analysis_controller_test.rb`:

```ruby
require "test_helper"

class PropertyAnalysisControllerTest < ActionDispatch::IntegrationTest
  setup { sign_in users(:family_admin) }

  test "show renders with defaults" do
    get property_analysis_path
    assert_response :ok
  end

  test "show accepts property and financing params" do
    get property_analysis_path(price: 2_000_000, monthly_rent: 5_000, ltv: 50, mortgage_rate: 4.5,
                               holding_years: 20, region: "us")
    assert_response :ok
    assert_select "h1", /Property analysis/i
  end
end
```

- [ ] **Step 3: Run to verify it fails**

Run: `bin/rails test test/controllers/property_analysis_controller_test.rb`
Expected: FAIL — no route / uninitialized constant `PropertyAnalysisController`.

- [ ] **Step 4: Create the controller**

Create `app/controllers/property_analysis_controller.rb`. Percent-style inputs (`ltv`, `mortgage_rate`, `opex_pct`, `vacancy_pct`) arrive as whole numbers from the form and are divided by 100; defaults come from the `real_estate_<region>` CMA:

```ruby
class PropertyAnalysisController < ApplicationController
  def show
    @currency = Current.family.currency
    @region = params[:region].to_s.downcase == "us" ? "us" : "cn"
    klass = "real_estate_#{@region}"
    cma = RealReturn::Cma.new
    c = cma.components(klass) || {}
    val = c["valuation"].is_a?(Hash) ? c["valuation"] : { "current" => 1.0, "target" => 1.0 }

    @holding_years = clamp(params[:holding_years].to_i, 5, 40, 30)
    @price = positive_or(params[:price], 1_000_000.0)
    default_rent = (@price * c.fetch("net_rental_yield", 0.03).to_f / 12.0).round
    @monthly_rent = positive_or(params[:monthly_rent], default_rent)
    @inputs = {
      ltv: pct_or(params[:ltv], 0.60), mortgage_rate: pct_or(params[:mortgage_rate], 0.05),
      amortization_years: clamp(params[:amortization_years].to_i, 5, 40, 30),
      opex_pct: pct_or(params[:opex_pct], 0.25), vacancy_pct: pct_or(params[:vacancy_pct], 0.05),
      inflation: pct_or(params[:inflation], @region == "us" ? 0.025 : 0.02)
    }

    @analysis = RealReturn::PropertyAnalysis.new(
      price: @price, monthly_rent: @monthly_rent, holding_years: @holding_years,
      ltv: @inputs[:ltv], mortgage_rate: @inputs[:mortgage_rate], amortization_years: @inputs[:amortization_years],
      opex_pct: @inputs[:opex_pct], vacancy_pct: @inputs[:vacancy_pct],
      real_rent_growth: c.fetch("real_rent_growth", 0.0).to_f,
      real_rent_growth_end: c.dig("glide", "real_rent_growth"),
      price_to_rent_current: val.fetch("current", 1.0).to_f, price_to_rent_target: val.fetch("target", 1.0).to_f,
      inflation: @inputs[:inflation], sigma: cma.sigma(klass) || 0.09,
      regimes: cma.regimes, regime_offsets: c.fetch("regime_offsets", {})
    )
    @cash_flow = @analysis.cash_flow
    @distribution = @analysis.distribution

    @benchmarks = %W[govbond equity_#{@region} gold deposit].map do |k|
      { key: k, expected_real_return: cma.expected_real_return(k, horizon: @holding_years), sigma: cma.sigma(k) }
    end

    @breadcrumbs = [ [ "Home", root_path ], [ "Property analysis", nil ] ]
  end

  private
    def clamp(value, min, max, default)
      v = value.to_i
      (min..max).cover?(v) ? v : default
    end

    def positive_or(raw, default)
      v = raw.to_f
      v.positive? ? v : default
    end

    def pct_or(raw, default)
      return default if raw.blank?

      v = raw.to_f / 100.0
      v >= 0 ? v : default
    end
end
```

- [ ] **Step 5: Run to verify it passes**

Run: `bin/rails test test/controllers/property_analysis_controller_test.rb`
Expected: PASS once the view exists (Task 4). It will FAIL here with a missing-template error — that's expected; proceed to Task 4 and re-run there. (If you prefer green-at-each-step, do Task 4 before re-running.)

- [ ] **Step 6: Commit**

```bash
git add config/routes.rb app/controllers/property_analysis_controller.rb test/controllers/property_analysis_controller_test.rb
git commit -m "$(cat <<'EOF'
feat(real_return): /property_analysis route + controller

Reads property/financing params (defaults from the real_estate CMA), builds a
PropertyAnalysis, computes cash flow + distribution + benchmark rows.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: View + nav link

**Files:**
- Create: `app/views/property_analyses/show.html.erb`
- Modify: `app/views/layouts/application.html.erb:6` (nav)

- [ ] **Step 1: Create the view**

Create `app/views/property_analyses/show.html.erb`:

```erb
<% content_for :page_header do %>
  <div class="space-y-1 mb-6">
    <h1 class="text-xl lg:text-3xl font-medium text-primary">Property analysis</h1>
    <p class="text-sm lg:text-base text-secondary">A levered, real-terms, regime-aware distribution for a single property — not a point forecast.</p>
  </div>
<% end %>

<% currency = @currency %>

<%# 1. Inputs %>
<div class="bg-container rounded-xl border border-secondary shadow-xs p-5 mb-5">
  <%= form_with url: property_analysis_path, method: :get, class: "flex flex-wrap items-end gap-4" do |f| %>
    <% [ [ :price, "Price (#{currency})", @price.round, 1 ], [ :monthly_rent, "Monthly rent", @monthly_rent.round, 1 ] ].each do |field, label, value, step| %>
      <div>
        <%= label_tag field, label, class: "block text-xs text-secondary mb-1" %>
        <%= number_field_tag field, value, step: step, class: "rounded-lg border border-secondary bg-container text-primary text-sm px-3 py-2 w-40" %>
      </div>
    <% end %>
    <div>
      <%= label_tag :region, "Region", class: "block text-xs text-secondary mb-1" %>
      <%= select_tag :region, options_for_select([ [ "China", "cn" ], [ "US", "us" ] ], @region), class: "rounded-lg border border-secondary bg-container text-primary text-sm px-3 py-2" %>
    </div>
    <% [ [ :holding_years, "Hold (yrs)", @holding_years ], [ :ltv, "LTV %", (@inputs[:ltv] * 100).round ], [ :mortgage_rate, "Rate %", (@inputs[:mortgage_rate] * 100).round(1) ], [ :amortization_years, "Amort (yrs)", @inputs[:amortization_years] ], [ :opex_pct, "Opex %", (@inputs[:opex_pct] * 100).round ], [ :vacancy_pct, "Vacancy %", (@inputs[:vacancy_pct] * 100).round ], [ :inflation, "Inflation %", (@inputs[:inflation] * 100).round(1) ] ].each do |field, label, value| %>
      <div>
        <%= label_tag field, label, class: "block text-xs text-secondary mb-1" %>
        <%= number_field_tag field, value, step: "any", class: "rounded-lg border border-secondary bg-container text-primary text-sm px-2 py-2 w-24" %>
      </div>
    <% end %>
    <%= f.submit "Update", class: "rounded-lg bg-gray-900 text-white text-sm font-medium px-4 py-2 cursor-pointer" %>
  <% end %>
</div>

<%# 2. Cash-flow pro forma %>
<div class="bg-container rounded-xl border border-secondary shadow-xs p-5 mb-5">
  <h2 class="text-lg font-medium text-primary mb-3">Cash flow (year 1, real)</h2>
  <div class="grid grid-cols-2 md:grid-cols-3 gap-4 text-sm">
    <% [
         [ "Gross yield", rr_pct_yr(@cash_flow[:gross_yield]) ],
         [ "Cap rate (net)", rr_pct_yr(@cash_flow[:cap_rate]) ],
         [ "NOI", rr_money(@cash_flow[:noi], currency) ],
         [ "Debt service", rr_money(@cash_flow[:debt_service], currency) ],
         [ "Cash-on-cash", @cash_flow[:cash_on_cash] ? rr_pct_yr(@cash_flow[:cash_on_cash]) : "—" ],
         [ "DSCR", @cash_flow[:dscr] ? @cash_flow[:dscr].round(2) : "—" ],
         [ "Break-even occupancy", @cash_flow[:break_even_occupancy] ? number_to_percentage(@cash_flow[:break_even_occupancy] * 100, precision: 0) : "—" ],
         [ "Down payment", rr_money(@cash_flow[:down_payment], currency) ]
       ].each do |label, value| %>
      <div>
        <p class="text-xs text-secondary"><%= label %></p>
        <p class="text-primary font-medium"><%= value %></p>
      </div>
    <% end %>
  </div>
</div>

<%# 3. Levered equity distribution %>
<div class="bg-container rounded-xl border border-secondary shadow-xs p-5 mb-5">
  <h2 class="text-lg font-medium text-primary mb-1">Levered real equity — distribution</h2>
  <p class="text-sm text-secondary mb-3">Shaded band p10–p90; line p50. Real terms; leverage cuts both ways.</p>
  <%= projection_fan_svg(@distribution[:years], @distribution[:p10], @distribution[:p50], @distribution[:p90]) %>
  <div class="flex justify-between text-xs text-subdued mt-1">
    <span><%= Date.current.year %></span><span><%= Date.current.year + @holding_years %></span>
  </div>
  <div class="grid grid-cols-2 md:grid-cols-4 gap-4 text-sm mt-4">
    <div><p class="text-xs text-secondary">Terminal p10</p><p class="text-destructive font-medium"><%= rr_money(@distribution[:terminal][:p10], currency) %></p></div>
    <div><p class="text-xs text-secondary">Terminal p50</p><p class="text-primary font-medium"><%= rr_money(@distribution[:terminal][:p50], currency) %></p></div>
    <div><p class="text-xs text-secondary">Terminal p90</p><p class="text-success font-medium"><%= rr_money(@distribution[:terminal][:p90], currency) %></p></div>
    <div><p class="text-xs text-secondary">Negative-equity paths</p><p class="text-primary font-medium"><%= number_to_percentage(@distribution[:negative_equity_share] * 100, precision: 0) %></p></div>
  </div>
  <p class="text-xs text-subdued mt-3">Annualized levered real return — p10 <%= @distribution[:annualized][:p10] ? rr_pct_yr(@distribution[:annualized][:p10]) : "—" %> · p50 <%= @distribution[:annualized][:p50] ? rr_pct_yr(@distribution[:annualized][:p50]) : "—" %> · p90 <%= @distribution[:annualized][:p90] ? rr_pct_yr(@distribution[:annualized][:p90]) : "—" %></p>
  <% if @distribution[:table].any? %>
    <table class="w-full text-sm mt-3">
      <thead><tr class="text-secondary text-left border-b border-secondary"><th class="py-1 pr-4 font-medium">Horizon</th><th class="py-1 pr-4 font-medium">p10</th><th class="py-1 pr-4 font-medium">p50</th><th class="py-1 font-medium">p90</th></tr></thead>
      <tbody>
        <% @distribution[:table].each do |row| %>
          <tr class="border-b border-secondary">
            <td class="py-1 pr-4 text-primary"><%= row[:years] %>y</td>
            <td class="py-1 pr-4 text-destructive"><%= rr_money(row[:p10], currency) %></td>
            <td class="py-1 pr-4 text-primary"><%= rr_money(row[:p50], currency) %></td>
            <td class="py-1 text-success"><%= rr_money(row[:p90], currency) %></td>
          </tr>
        <% end %>
      </tbody>
    </table>
  <% end %>
</div>

<%# 4. Benchmark comparison %>
<div class="bg-container rounded-xl border border-secondary shadow-xs p-5 mb-5">
  <h2 class="text-lg font-medium text-primary mb-3">vs liquid alternatives (unlevered, real)</h2>
  <table class="w-full text-sm">
    <thead><tr class="text-secondary text-left border-b border-secondary"><th class="py-1 pr-4 font-medium">Asset</th><th class="py-1 pr-4 font-medium">Expected real return</th><th class="py-1 font-medium">σ</th></tr></thead>
    <tbody>
      <% @benchmarks.each do |b| %>
        <tr class="border-b border-secondary">
          <td class="py-1 pr-4 text-primary"><%= b[:key] %></td>
          <td class="py-1 pr-4 text-secondary"><%= rr_pct_yr(b[:expected_real_return]) %></td>
          <td class="py-1 text-secondary"><%= number_to_percentage((b[:sigma] || 0) * 100, precision: 0) %></td>
        </tr>
      <% end %>
    </tbody>
  </table>
</div>

<%# 5. Assumptions / notes %>
<div class="bg-container rounded-xl border border-secondary shadow-xs p-5">
  <h2 class="text-lg font-medium text-primary mb-1">Assumptions & what could break this</h2>
  <div class="text-sm text-secondary space-y-1">
    <p>Real price path = real rent growth + valuation reversion (<%= @analysis ? "price/rent reverts over the horizon" : "" %>) + a per-path macro regime, with σ from the real-estate CMA. Income (NOI) grows deterministically at the rent-growth assumption (v1 simplification — price carries the risk). Debt is nominal; its real value erodes with inflation.</p>
    <p>These are <span class="text-primary font-medium">assumptions, not data</span>: city demographics, supply, current rates, and policy are <span class="text-primary">not</span> researched here — set them via the inputs. Leverage amplifies both tails; see the negative-equity share.</p>
  </div>
</div>
```

- [ ] **Step 2: Add the nav link**

In `app/views/layouts/application.html.erb`, find the nav item line (line ~6):
```erb
  { name: "Projection", path: projection_path, icon: "telescope", icon_custom: false, active: page_active?(projection_path) },
```
Add immediately after it:
```erb
  { name: "Property analysis", path: property_analysis_path, icon: "home", icon_custom: false, active: page_active?(property_analysis_path) },
```

- [ ] **Step 3: Lint + run the controller test**

Run: `bundle exec erb_lint ./app/views/property_analyses/show.html.erb -a` (expect no offenses)
Run: `bin/rails test test/controllers/property_analysis_controller_test.rb`
Expected: PASS (renders :ok; `h1` matches "Property analysis").

- [ ] **Step 4: Commit**

```bash
git add app/views/property_analyses/show.html.erb app/views/layouts/application.html.erb
git commit -m "$(cat <<'EOF'
feat(real_return): property analysis view + nav link

Inputs form, cash-flow pro forma, levered equity fan + terminal/horizon tables +
ruin share, benchmark comparison, and an assumptions/limitations panel.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: Full verification

**Files:** none.

- [ ] **Step 1: Full suite** — `bin/rails test` — Expected: 0 failures; only the known pre-existing Plaid-env errors (6 `Provider::PlaidTest` + 1 `UsersControllerTest#test_admin_can_reset_family_data`). Confirm `property_analysis*` tests pass and the error count hasn't grown.
- [ ] **Step 2: Ruby lint** — `bin/rubocop -a app/models/real_return/property_analysis.rb app/controllers/property_analysis_controller.rb` — Expected: no offenses.
- [ ] **Step 3: ERB lint** — `bundle exec erb_lint ./app/**/*.erb` — Expected: no offenses.
- [ ] **Step 4: Security** — `bin/brakeman --no-pager --no-progress` — Expected: 0 warnings (no SQL, no user-input rendering beyond numeric params).
- [ ] **Step 5: Sanity** — `bin/rails runner 'a = RealReturn::PropertyAnalysis.new(price: 1_000_000.0, monthly_rent: 3_000.0, holding_years: 30, ltv: 0.6, mortgage_rate: 0.05, amortization_years: 30, opex_pct: 0.25, vacancy_pct: 0.05, real_rent_growth: 0.0, price_to_rent_current: 1.35, price_to_rent_target: 1.0, inflation: 0.02, sigma: 0.09, regimes: {"base"=>0.6,"bear"=>0.25,"bull"=>0.15}, regime_offsets: {"bear"=>-0.03,"bull"=>0.01}, paths: 3000, seed: 9); cf = a.cash_flow; d = a.distribution; puts "coc=%.3f dscr=%.2f | term p10=%d p50=%d p90=%d ruin=%.0f%%" % [cf[:cash_on_cash], cf[:dscr], d[:terminal][:p10], d[:terminal][:p50], d[:terminal][:p90], d[:negative_equity_share]*100]'` — paste output; sanity-check the levered distribution + ruin share look reasonable.
- [ ] **Step 6: Final whole-feature review** — dispatch a reviewer over `git diff <task1-commit>~1..HEAD`: confirm the model math (cash flow + levered real MC with inflation-deflated nominal debt), controller defaults, view panels, and nav link; confirm reuse of the real_return engine and that the portfolio Projection page is untouched.

---

## Self-Review

**Spec coverage:** cash-flow pro forma (Step 1) → Task 1 ✓; levered real MC w/ regime+glide+valuation, nominal-debt-deflated, percentiles + annualized + ruin + horizon table (Steps 7/8/10) → Task 2 ✓; standalone page/route/controller w/ CMA defaults → Task 3 ✓; view (form + cash-flow + fan + tables + benchmarks + notes) + nav (Step 11 benchmark; Step 9 noted) → Task 4 ✓; verification → Task 5 ✓. Deferred (research Steps 2–5, memo Step 12) are noted in the view's assumptions panel, per spec non-goals. ✓

**Placeholder scan:** none — complete code in every code step; route/nav give exact insertion text.

**Type consistency:** `PropertyAnalysis.new(...)` keyword set matches the controller's call (Task 3) and the test builder (Tasks 1–2). `cash_flow` returns the Hash keys the view reads (Task 4: `:gross_yield/:cap_rate/:noi/:debt_service/:cash_on_cash/:dscr/:break_even_occupancy/:down_payment`). `distribution` returns `:years/:p10/:p25/:p50/:p75/:p90/:terminal{:p10,:p50,:p90}/:annualized{...}/:negative_equity_share/:table[{:years,:p10,:p50,:p90}]` — consumed identically by the view (Task 4). `@benchmarks` rows `{:key,:expected_real_return,:sigma}` match the view. Controller ivars (`@price/@monthly_rent/@holding_years/@inputs/@region/@cash_flow/@distribution/@benchmarks/@currency`) all used by the view. `projection_fan_svg(years, p15, p50, p85, ...)` called with (years, p10, p50, p90) — positional band args, correct.
