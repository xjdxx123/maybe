# Projection Comparison + Traceability — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** On `/projection`, compare the current basket against model portfolios (presets + custom allocation) and show a "methodology / formulas" panel making every number traceable.

**Architecture:** `RealReturn::ModelPortfolio` turns a bucket-weight allocation into a `MonteCarlo` asset list; `RealReturn::PortfolioComparison` projects the current basket + each alternative (same capital/savings/seed) into rows; `Cma#components` exposes raw building-block inputs; `ProjectionsHelper` overlays alternative median lines on the fan + renders per-class formulas; the controller/view show a comparison table, overlay, custom-weight inputs, and a methodology panel.

**Tech Stack:** Ruby 3.4.4 / Rails 7.2, Minitest, existing `RealReturn::{Cma, AssetClass, Correlation, MonteCarlo, Projection, Region}`.

**Depends on:** P-A/P-B/P-D (all on `feature/real-return`).

**Conventions:** Run from `/Users/clintongao/coding/maybe`; if `ruby -v` ≠ 3.4.4 prefix `export PATH="$HOME/.rbenv/shims:$PATH"; `. Tests: `bin/rails test <path>`. Don't run `bin/rails server`. Functional Tailwind tokens; `icon` helper.

---

## File Structure

| File | Responsibility |
|---|---|
| `app/models/real_return/cma.rb` (modify) | add `components(asset_class)` |
| `app/models/real_return/model_portfolio.rb` (create) | presets + bucket→class + `assets_for` + `expected_real_return` |
| `app/models/real_return/portfolio_comparison.rb` (create) | rows: Current + presets + custom |
| `app/helpers/projections_helper.rb` (modify) | `projection_fan_svg(..., overlays:)` + `projection_formula` |
| `app/controllers/projections_controller.rb` (modify) | custom-weight params + `@comparison` |
| `app/views/projections/show.html.erb` (modify) | custom inputs + comparison table + overlay + methodology panel |
| tests | model + helper + controller tests |

---

## Task 1: `Cma#components` + `RealReturn::ModelPortfolio`

**Files:** modify `app/models/real_return/cma.rb`; create `app/models/real_return/model_portfolio.rb`; create `test/models/real_return/model_portfolio_test.rb`; append to `test/models/real_return/cma_test.rb`.

- [ ] **Step 1: Failing tests.** Append to `test/models/real_return/cma_test.rb` (before its final `end`):

```ruby
  test "components exposes the raw building-block inputs" do
    c = cma.components("equity_cn")
    assert_equal "equity", c["kind"]
    assert_in_delta 0.025, c["dividend_yield"], 1e-9
    assert_nil cma.components("nope")
  end
```

Create `test/models/real_return/model_portfolio_test.rb`:

```ruby
require "test_helper"

class RealReturn::ModelPortfolioTest < ActiveSupport::TestCase
  def cma
    RealReturn::Cma.new(path: Rails.root.join("test", "fixtures", "files", "real_return", "cma.sample.yml"))
  end

  test "bucket_class maps buckets to region-aware CMA classes" do
    assert_equal "equity_cn", RealReturn::ModelPortfolio.bucket_class(:equity, "CNY")
    assert_equal "equity_us", RealReturn::ModelPortfolio.bucket_class(:equity, "USD")
    assert_equal "govbond", RealReturn::ModelPortfolio.bucket_class(:bonds, "CNY")
    assert_equal "real_estate_cn", RealReturn::ModelPortfolio.bucket_class(:real_estate, "CNY")
    assert_equal "deposit", RealReturn::ModelPortfolio.bucket_class(:cash, "CNY")
  end

  test "assets_for splits total by normalized weights into CMA classes" do
    assets = RealReturn::ModelPortfolio.assets_for({ equity: 0.6, bonds: 0.4 }, total: 1000.0, currency: "CNY", cma: cma)
    by_class = assets.to_h { |a| [ a[:asset_class], a ] }
    assert_in_delta 600.0, by_class["equity_cn"][:value], 1e-6
    assert_in_delta 400.0, by_class["govbond"][:value], 1e-6
    assert_in_delta 0.045, by_class["equity_cn"][:expected_real_return], 1e-9 # cma.sample equity_cn
  end

  test "weights need not sum to 1 (normalized)" do
    assets = RealReturn::ModelPortfolio.assets_for({ equity: 30, bonds: 10 }, total: 1000.0, currency: "CNY", cma: cma)
    assert_in_delta 1000.0, assets.sum { |a| a[:value] }, 1e-6
  end

  test "expected_real_return is the weighted average" do
    er = RealReturn::ModelPortfolio.expected_real_return({ equity: 0.6, bonds: 0.4 }, currency: "CNY", cma: cma)
    assert_in_delta (0.6 * 0.045 + 0.4 * 0.004), er, 1e-9
  end

  test "all-cash maps to deposit" do
    assert_in_delta(-0.003, RealReturn::ModelPortfolio.expected_real_return({ cash: 1.0 }, currency: "CNY", cma: cma), 1e-9)
  end

  test "PRESETS lists the model portfolios" do
    assert_equal [ "All equity", "60/40", "Diversified", "All cash" ], RealReturn::ModelPortfolio::PRESETS.keys
  end
end
```

- [ ] **Step 2: Run → fail** (`uninitialized constant RealReturn::ModelPortfolio`, and the cma components test): `bin/rails test test/models/real_return/model_portfolio_test.rb test/models/real_return/cma_test.rb`

- [ ] **Step 3: Add `Cma#components`.** In `app/models/real_return/cma.rb`, add this public method right after `sigma`:

```ruby
    # Raw building-block inputs for an asset class (Hash with string keys), or nil.
    def components(asset_class)
      data[asset_class.to_s]
    end
```

- [ ] **Step 4: Create `app/models/real_return/model_portfolio.rb`:**

```ruby
module RealReturn
  # Turns a bucket-weight allocation into a MonteCarlo asset list, and computes its
  # weighted expected real return, using the CMA. Buckets map (region-aware) to CMA classes.
  module ModelPortfolio
    # name => { bucket => weight }
    PRESETS = {
      "All equity" => { equity: 1.0 },
      "60/40" => { equity: 0.6, bonds: 0.4 },
      "Diversified" => { equity: 0.4, bonds: 0.2, real_estate: 0.15, gold: 0.15, cash: 0.1 },
      "All cash" => { cash: 1.0 }
    }.freeze

    BUCKETS = %i[equity bonds real_estate gold cash].freeze

    module_function

    def bucket_class(bucket, currency)
      region = Region.real_estate(currency).downcase
      case bucket.to_sym
      when :equity then "equity_#{region}"
      when :bonds then "govbond"
      when :real_estate then "real_estate_#{region}"
      when :gold then "gold"
      when :cash then "deposit"
      end
    end

    # [{ value:, asset_class:, expected_real_return:, sigma: }], total split by normalized weights.
    def assets_for(weights, total:, currency:, cma:)
      r = resolved(weights, currency, cma)
      sum = r.sum { |x| x[:w] }
      return [] if sum <= 0

      r.map do |x|
        { value: total * (x[:w] / sum), asset_class: x[:klass], expected_real_return: x[:er], sigma: x[:sigma] }
      end
    end

    # Weighted average expected real return over resolved buckets, or nil.
    def expected_real_return(weights, currency:, cma:)
      r = resolved(weights, currency, cma)
      sum = r.sum { |x| x[:w] }
      return nil if sum <= 0

      r.sum(0.0) { |x| x[:er] * (x[:w] / sum) }
    end

    # private-ish: buckets with positive weight AND a valid CMA class.
    def resolved(weights, currency, cma)
      weights.filter_map do |bucket, weight|
        w = weight.to_f
        next nil if w <= 0

        klass = bucket_class(bucket, currency)
        er = klass && cma.expected_real_return(klass)
        sigma = klass && cma.sigma(klass)
        next nil if er.nil? || sigma.nil?

        { w: w, klass: klass, er: er, sigma: sigma }
      end
    end
  end
end
```

- [ ] **Step 5: Run → pass:** `bin/rails test test/models/real_return/model_portfolio_test.rb test/models/real_return/cma_test.rb`

- [ ] **Step 6: Commit**

```bash
git add app/models/real_return/cma.rb app/models/real_return/model_portfolio.rb test/models/real_return/model_portfolio_test.rb test/models/real_return/cma_test.rb
git commit -m "feat(real_return): add ModelPortfolio + Cma#components

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: `RealReturn::PortfolioComparison`

**Files:** create `app/models/real_return/portfolio_comparison.rb`; create `test/models/real_return/portfolio_comparison_test.rb`.

- [ ] **Step 1: Failing test.** Create `test/models/real_return/portfolio_comparison_test.rb`:

```ruby
require "test_helper"

class RealReturn::PortfolioComparisonTest < ActiveSupport::TestCase
  include LedgerTestingHelper

  def cma
    RealReturn::Cma.new(path: Rails.root.join("test", "fixtures", "files", "real_return", "cma.sample.yml"))
  end

  def family_with_property
    family = families(:empty)
    family.update!(currency: "CNY")
    create_account_with_ledger(
      account: { type: Property, currency: "CNY", balance: 0 },
      entries: [
        { type: "opening_anchor", date: Date.new(2010, 1, 1), balance: 1_000_000 },
        { type: "current_anchor", date: Date.new(2024, 1, 1), balance: 2_000_000 }
      ]
    )
    family
  end

  test "rows include Current plus the presets, each with ordered terminals" do
    comp = RealReturn::PortfolioComparison.new(family_with_property, as_of: Date.new(2024, 1, 1),
      horizon: 20, cma: cma, paths: 1500, seed: 9)
    rows = comp.rows

    assert_equal "Current", rows.first[:name]
    names = rows.map { |r| r[:name] }
    assert_includes names, "All equity"
    assert_includes names, "All cash"
    rows.each do |r|
      assert_equal 21, r[:median].size # horizon + 1
      assert r[:terminal][:p15] <= r[:terminal][:p50]
      assert r[:terminal][:p50] <= r[:terminal][:p85]
    end
  end

  test "all-cash row expected real return equals the deposit CMA" do
    comp = RealReturn::PortfolioComparison.new(family_with_property, as_of: Date.new(2024, 1, 1),
      horizon: 10, cma: cma, paths: 1000, seed: 9)
    cash_row = comp.rows.find { |r| r[:name] == "All cash" }
    assert_in_delta(-0.003, cash_row[:expected_real_return], 1e-9)
  end

  test "custom weights add a Custom row" do
    comp = RealReturn::PortfolioComparison.new(family_with_property, as_of: Date.new(2024, 1, 1),
      horizon: 10, custom_weights: { equity: 0.5, bonds: 0.5 }, cma: cma, paths: 1000, seed: 9)
    assert_includes comp.rows.map { |r| r[:name] }, "Custom"
  end
end
```

- [ ] **Step 2: Run → fail** (`uninitialized constant RealReturn::PortfolioComparison`): `bin/rails test test/models/real_return/portfolio_comparison_test.rb`

- [ ] **Step 3: Implement.** Create `app/models/real_return/portfolio_comparison.rb`:

```ruby
module RealReturn
  # Projects the current basket + alternative model portfolios (same capital, savings,
  # horizon, correlation, seed — only the allocation differs) into comparable rows.
  class PortfolioComparison
    def initialize(family, as_of: Date.current, horizon: 30, annual_contribution: 0.0, custom_weights: nil,
                   cma: Cma.new, reference_data: ReferenceData.default, correlation: Correlation.new,
                   paths: 5000, seed: 123_456)
      @family = family
      @as_of = as_of
      @horizon = horizon
      @annual_contribution = annual_contribution
      @custom_weights = custom_weights
      @cma = cma
      @reference_data = reference_data
      @correlation = correlation
      @paths = paths
      @seed = seed
      @currency = family.currency
    end

    # Ordered rows: Current (actual basket) first, then presets, then Custom (if given).
    # Each: { name:, weights: (nil for Current), expected_real_return:, median: [..], terminal: {p15:,p50:,p85:} }
    def rows
      projection = Projection.new(@family, as_of: @as_of, cma: @cma, reference_data: @reference_data,
                                  correlation: @correlation, paths: @paths, seed: @seed)
      current = projection.project(horizon: @horizon, annual_contribution: @annual_contribution)
      start_value = current[:p50].first

      out = [ build_row("Current", nil, current, current_expected_return(projection.assets, start_value)) ]
      return out if start_value <= 0

      ModelPortfolio::PRESETS.each { |name, weights| out << alternative_row(name, weights, start_value) }
      if @custom_weights && @custom_weights.values.sum { |w| w.to_f } > 0
        out << alternative_row("Custom", @custom_weights, start_value)
      end
      out
    end

    private
      def alternative_row(name, weights, total)
        assets = ModelPortfolio.assets_for(weights, total: total, currency: @currency, cma: @cma)
        result = MonteCarlo.new(assets: assets, correlation: @correlation, horizon: @horizon,
                                annual_contribution: @annual_contribution, paths: @paths, seed: @seed).run
        build_row(name, weights, result, ModelPortfolio.expected_real_return(weights, currency: @currency, cma: @cma))
      end

      def build_row(name, weights, result, expected_real_return)
        {
          name: name, weights: weights, expected_real_return: expected_real_return,
          median: result[:p50],
          terminal: { p15: result[:p15].last, p50: result[:p50].last, p85: result[:p85].last }
        }
      end

      def current_expected_return(assets, total)
        return nil if total <= 0 || assets.empty?

        assets.sum(0.0) { |a| a[:expected_real_return] * (a[:value] / total) }
      end
  end
end
```

- [ ] **Step 4: Run → pass:** `bin/rails test test/models/real_return/portfolio_comparison_test.rb`

- [ ] **Step 5: Commit**

```bash
git add app/models/real_return/portfolio_comparison.rb test/models/real_return/portfolio_comparison_test.rb
git commit -m "feat(real_return): add PortfolioComparison (current vs model portfolios)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: `ProjectionsHelper` — overlays + formula

**Files:** modify `app/helpers/projections_helper.rb`; create `test/helpers/projections_helper_test.rb`.

- [ ] **Step 1: Failing test.** Create `test/helpers/projections_helper_test.rb`:

```ruby
require "test_helper"

class ProjectionsHelperTest < ActionView::TestCase
  test "fan svg with overlays draws dashed polylines and scales to the combined max" do
    svg = projection_fan_svg([ 0, 1, 2 ], [ 100, 100, 100 ], [ 100, 110, 120 ], [ 100, 120, 140 ],
      overlays: [ { label: "All equity", values: [ 100, 200, 400 ] } ])
    assert_includes svg, "stroke-dasharray"
    assert_includes svg, "polyline"
    assert svg.html_safe?
  end

  test "formula renders the building-block arithmetic for an equity class" do
    cma = RealReturn::Cma.new(path: Rails.root.join("test", "fixtures", "files", "real_return", "cma.sample.yml"))
    str = projection_formula(cma, "equity_cn")
    assert_includes str, "="
    assert_includes str, "%"
  end

  test "formula handles bond / cash / gold kinds" do
    cma = RealReturn::Cma.new(path: Rails.root.join("test", "fixtures", "files", "real_return", "cma.sample.yml"))
    assert_includes projection_formula(cma, "govbond"), "real yield"
    assert_includes projection_formula(cma, "deposit"), "real rate"
    assert_includes projection_formula(cma, "gold"), "≈"
  end
end
```

- [ ] **Step 2: Run → fail** (wrong arity / NoMethod): `bin/rails test test/helpers/projections_helper_test.rb`

- [ ] **Step 3: Implement.** Replace the entire `app/helpers/projections_helper.rb` with:

```ruby
module ProjectionsHelper
  OVERLAY_COLORS = %w[#2563eb #d97706 #7c3aed #0891b2 #db2777].freeze

  # Server-rendered SVG fan: shaded p15..p85 band + p50 median line + optional dashed
  # overlay median lines. overlays: [{ label:, values: [..] }]. Returns an html_safe SVG.
  def projection_fan_svg(years, p15, p50, p85, overlays: [], width: 640, height: 220, pad: 6)
    n = years.size
    max = ([ p85.max ] + overlays.map { |o| o[:values].max }).map(&:to_f).max
    return "".html_safe if n < 2 || max <= 0

    xs = ->(i) { (pad + (width - 2 * pad) * (i.to_f / (n - 1))).round(1) }
    ys = ->(v) { (height - pad - (height - 2 * pad) * (v.to_f / max)).round(1) }
    pts = ->(arr) { (0...n).map { |i| "#{xs.call(i)},#{ys.call(arr[i])}" }.join(" ") }

    band = ((0...n).map { |i| "#{xs.call(i)},#{ys.call(p85[i])}" } +
            (n - 1).downto(0).map { |i| "#{xs.call(i)},#{ys.call(p15[i])}" }).join(" ")

    overlay_svg = overlays.each_with_index.map do |o, idx|
      %(<polyline points="#{pts.call(o[:values])}" fill="none" stroke="#{OVERLAY_COLORS[idx % OVERLAY_COLORS.size]}" stroke-width="1.5" stroke-dasharray="4 3" />)
    end.join("\n")

    <<~SVG.html_safe
      <svg viewBox="0 0 #{width} #{height}" class="w-full text-success" role="img" aria-label="Projection fan chart">
        <polygon points="#{band}" fill="currentColor" fill-opacity="0.15" />
        <polyline points="#{pts.call(p50)}" fill="none" stroke="currentColor" stroke-width="2" />
        #{overlay_svg}
      </svg>
    SVG
  end

  # Color for the Nth overlay (to label the legend/table consistently with the chart).
  def projection_overlay_color(index)
    OVERLAY_COLORS[index % OVERLAY_COLORS.size]
  end

  def projection_asset_classes(assets)
    assets.map { |a| a[:asset_class] }.uniq
  end

  # Human, traceable building-block formula for an asset class, e.g.
  # "2.8% − 1.0% + 3.5% + 0.0% = 5.3%/yr". Uses Cma#components.
  def projection_formula(cma, asset_class)
    c = cma.components(asset_class)
    er = cma.expected_real_return(asset_class)
    return "—" if c.nil? || er.nil?

    pct = ->(v) { "#{(v.to_f * 100).round(1)}%" }
    body =
      case c["kind"]
      when "equity"
        "dividend #{pct.call(c['dividend_yield'])} − dilution #{pct.call(c['net_dilution'])} + real growth #{pct.call(c['real_earnings_growth'])} + valuation #{pct.call(c['valuation_reversion'])}"
      when "real_estate"
        "rental yield #{pct.call(c['net_rental_yield'])} + real rent growth #{pct.call(c['real_rent_growth'])} + valuation #{pct.call(c['valuation_reversion'])}"
      when "bond"
        "real yield #{pct.call(c['real_yield'])}"
      when "cash"
        "real rate #{pct.call(c['real_rate'])}"
      else
        "≈ #{pct.call(c['real_return'])} (golden constant / assumption)"
      end
    "#{body} = #{pct.call(er)}/yr"
  end
end
```

- [ ] **Step 4: Run → pass:** `bin/rails test test/helpers/projections_helper_test.rb`

- [ ] **Step 5: Commit**

```bash
git add app/helpers/projections_helper.rb test/helpers/projections_helper_test.rb
git commit -m "feat(real_return): fan overlays + traceable per-class formula helper

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: Controller + view (comparison + methodology)

**Files:** modify `app/controllers/projections_controller.rb`, `app/views/projections/show.html.erb`.

- [ ] **Step 1: Extend the controller.** In `app/controllers/projections_controller.rb` `#show`, add (after the existing `@tier_future = ...` line, before `@breadcrumbs`):

```ruby
    @custom_weights = {
      equity: params.dig(:w, :equity).to_f, bonds: params.dig(:w, :bonds).to_f,
      real_estate: params.dig(:w, :real_estate).to_f, gold: params.dig(:w, :gold).to_f,
      cash: params.dig(:w, :cash).to_f
    }
    @comparison = RealReturn::PortfolioComparison.new(
      Current.family, as_of: Date.current, horizon: @horizon, annual_contribution: @contribution,
      custom_weights: @custom_weights
    ).rows
```

- [ ] **Step 2: Add comparison + methodology to the view.** In `app/views/projections/show.html.erb`:

(a) Add custom-weight inputs inside the existing params `form_with` block, right BEFORE the `<%= f.submit "Update" ... %>` line:

```erb
      <% { equity: "Equity", bonds: "Bonds", real_estate: "Real estate", gold: "Gold", cash: "Cash" }.each do |bucket, label| %>
        <div>
          <%= label_tag "w_#{bucket}", "#{label} %", class: "block text-xs text-secondary mb-1" %>
          <%= number_field_tag "w[#{bucket}]", (@custom_weights[bucket].positive? ? @custom_weights[bucket].round : nil), placeholder: "0", min: 0, class: "rounded-lg border border-secondary bg-container text-primary text-sm px-2 py-2 w-20" %>
        </div>
      <% end %>
```

(b) Change the fan-chart render line. Find:

```erb
    <%= projection_fan_svg(@result[:years], @result[:p15], @result[:p50], @result[:p85]) %>
```

Replace with (overlay the alternatives' median lines):

```erb
    <% overlays = @comparison.reject { |r| r[:name] == "Current" }.map { |r| { label: r[:name], values: r[:median] } } %>
    <%= projection_fan_svg(@result[:years], @result[:p15], @result[:p50], @result[:p85], overlays: overlays) %>
```

(c) Insert a comparison-table card immediately AFTER the terminal-figures card's closing `</div>` (the card whose heading is `In <%= ... %> (real)`) and BEFORE the Wealth-tier card:

```erb
  <%# Portfolio comparison %>
  <div class="bg-container rounded-xl border border-secondary shadow-xs p-5 mb-5">
    <h2 class="text-lg font-medium text-primary mb-1">Compare portfolios</h2>
    <p class="text-sm text-secondary mb-3">Same starting capital and annual savings, different allocation. Dashed lines on the chart above. Real terms.</p>
    <div class="overflow-x-auto">
      <table class="w-full text-sm">
        <thead>
          <tr class="text-secondary text-left border-b border-secondary">
            <th class="py-2 pr-4 font-medium">Portfolio</th>
            <th class="py-2 pr-4 font-medium">Expected real return</th>
            <th class="py-2 pr-4 font-medium">Pessimistic</th>
            <th class="py-2 pr-4 font-medium">Neutral</th>
            <th class="py-2 pr-4 font-medium">Optimistic</th>
          </tr>
        </thead>
        <tbody>
          <% @comparison.each_with_index do |r, idx| %>
            <tr class="border-b border-secondary <%= "bg-container-inset" if r[:name] == "Current" %>">
              <td class="py-2 pr-4 text-primary font-medium">
                <% unless r[:name] == "Current" %><span class="inline-block w-3 border-t-2 border-dashed mr-1 align-middle" style="border-color: <%= projection_overlay_color(idx - 1) %>"></span><% end %>
                <%= r[:name] %>
              </td>
              <td class="py-2 pr-4 text-secondary"><%= rr_pct_yr(r[:expected_real_return]) %></td>
              <td class="py-2 pr-4 text-destructive"><%= rr_money(r[:terminal][:p15], currency) %></td>
              <td class="py-2 pr-4 text-primary"><%= rr_money(r[:terminal][:p50], currency) %></td>
              <td class="py-2 pr-4 text-success"><%= rr_money(r[:terminal][:p85], currency) %></td>
            </tr>
          <% end %>
        </tbody>
      </table>
    </div>
  </div>
```

(d) REPLACE the existing "Assumptions" card (heading `Assumptions`) with a fuller methodology panel:

```erb
  <%# Methodology / formulas (traceable) %>
  <div class="bg-container rounded-xl border border-secondary shadow-xs p-5">
    <h2 class="text-lg font-medium text-primary mb-1">Methodology — every number is traceable</h2>
    <p class="text-sm text-secondary mb-3">Forward expected real returns are built block-by-block (editable in <code>config/real_return/cma.yml</code>).</p>
    <table class="w-full text-sm mb-4">
      <thead>
        <tr class="text-secondary text-left border-b border-secondary">
          <th class="py-2 pr-4 font-medium">Asset class</th>
          <th class="py-2 pr-4 font-medium">Building-block formula</th>
        </tr>
      </thead>
      <tbody>
        <% projection_asset_classes(@assets).each do |klass| %>
          <tr class="border-b border-secondary">
            <td class="py-2 pr-4 text-primary align-top"><%= klass %></td>
            <td class="py-2 pr-4 text-secondary"><%= projection_formula(@cma, klass) %></td>
          </tr>
        <% end %>
      </tbody>
    </table>
    <div class="text-sm text-secondary space-y-1">
      <p><span class="text-primary font-medium">Monte Carlo:</span> each asset's annual real return ~ correlated lognormal (mean = expected real return, vol = σ); 5,000 paths; bands are the 15th / 50th / 85th percentiles. Parameters: correlation ρ = 0.25, horizon <%= @horizon %>y, annual savings <%= rr_money(@contribution, currency) %>, fixed RNG seed (reproducible).</p>
      <p><span class="text-primary font-medium">Real terms:</span> real = (1 + nominal) ÷ (1 + inflation) − 1 (Fisher). All values are today's purchasing power.</p>
    </div>
  </div>
```

- [ ] **Step 3: Add a controller test for the custom-weights path.** Append to `test/controllers/projections_controller_test.rb` before its final `end`:

```ruby
  test "show accepts custom allocation weights" do
    get projection_path(years: 20, w: { equity: 50, bonds: 30, gold: 20 })
    assert_response :ok
  end
```

- [ ] **Step 4: Verify it renders:** `bin/rails test test/controllers/projections_controller_test.rb` → 3 runs, 0 failures. If a template/NoMethod error, STOP and report BLOCKED with the full error.

- [ ] **Step 5: Lint:** `bundle exec erb_lint app/views/projections/show.html.erb -a` → clean.

- [ ] **Step 6: Whole suite + rubocop:**

```bash
bin/rails test test/models/real_return/ test/helpers/projections_helper_test.rb test/controllers/projections_controller_test.rb
bin/rubocop app/models/real_return/ app/helpers/projections_helper.rb app/controllers/projections_controller.rb
```
Expected: all green; no offenses.

- [ ] **Step 7: Commit**

```bash
git add app/controllers/projections_controller.rb app/views/projections/show.html.erb test/controllers/projections_controller_test.rb
git commit -m "feat(real_return): projection comparison table + overlay + methodology panel

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: Browser verification (controller-executed, Claude_Preview)

- [ ] **Step 1:** `bin/rails tailwindcss:build`; clear any stale server on :3000 (kill pid + `rm -f tmp/pids/server.pid`).
- [ ] **Step 2:** `preview_start` (name `maybe`); sign in `admin@maybe.local` / `password` (set input values via native setter + `input` event, then `form.submit()`).
- [ ] **Step 3:** Navigate to `/projection`. Screenshot. Confirm: the fan shows the current band/median PLUS dashed overlay lines; the "Compare portfolios" table lists Current + All equity / 60/40 / Diversified / All cash with expected real return + pess/neutral/opt terminals (All equity's median should clearly exceed Current's, given the property-heavy basket); the "Methodology" panel shows per-class building-block formulas (e.g. real_estate_cn = rental yield + growth + valuation = 0.6%/yr) + the MC parameters + Fisher. Check `preview_console_logs`.
- [ ] **Step 4:** Enter custom weights (e.g. Equity 50, Bonds 30, Gold 20) → Update → confirm a "Custom" row + dashed line appear.
- [ ] **Step 5:** Fix anything broken; stop the preview server when done.

---

## Done criteria

- `bin/rails test test/models/real_return/ test/helpers/ test/controllers/projections_controller_test.rb` passes.
- `/projection` shows the comparison table + overlaid alternative median lines + a traceable methodology panel (per-class formulas + MC params + Fisher); custom weights add a Custom portfolio. Verified in the browser.
- erb_lint + rubocop clean on touched files.

**This completes the projection comparison + traceability feature.**
