# Real-return Methodology Provenance Display — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make every expected-real-return number on the Projection page traceable in-page — each building-block input shown with its signed contribution, an observable-vs-assumption tag, and its source.

**Architecture:** A single source of truth in `RealReturn::Cma` (`contributions`) drives both the headline number (`expected_real_return`, summed) and a decorated `breakdown` (labels + type + source). `PortfolioComparison#referenced_asset_classes` yields the page-referenced union of classes (held ∪ model-portfolio), which the methodology panel renders as collapsible `<details>` breakdown tables.

**Tech Stack:** Rails 7 (Ruby), Minitest + fixtures, ERB views, TailwindCSS design tokens, Hotwire-first (`<details>/<summary>`).

**Spec:** `docs/superpowers/specs/2026-05-31-real-return-methodology-provenance-design.md`

**Commit policy note:** This repo's `CLAUDE.md` says "commit only when the user asks." Commit steps are included below per plan convention; during execution, confirm with the user before running them (or get blanket approval up front). All commit messages end with the required `Co-Authored-By` trailer.

---

### Task 1: `Cma#breakdown` + single-source `contributions` + `metadata`

**Files:**
- Modify: `app/models/real_return/cma.rb`
- Modify (test fixture): `test/fixtures/files/real_return/cma.sample.yml`
- Test: `test/models/real_return/cma_test.rb`

- [ ] **Step 1: Add a `sources:` block to the sample fixture so the breakdown source test has data**

In `test/fixtures/files/real_return/cma.sample.yml`, add a `sources:` key under the existing `equity_cn` (leave all numbers unchanged):

```yaml
equity_cn:
  kind: equity
  dividend_yield: 0.025
  net_dilution: 0.005
  real_earnings_growth: 0.030
  valuation_reversion: -0.005
  sigma: 0.20
  sources:
    dividend_yield: "sample dividend source"
```

- [ ] **Step 2: Write the failing tests**

Append to `test/models/real_return/cma_test.rb` (inside the class):

```ruby
  test "breakdown decomposes equity into signed contributions that sum to the expected real return" do
    bd = cma.breakdown("equity_cn")
    assert_equal %w[dividend_yield net_dilution real_earnings_growth valuation_reversion], bd.map { |c| c[:key] }

    dilution = bd.find { |c| c[:key] == "net_dilution" }
    # stored +0.005 but SUBTRACTED in the formula -> contribution is negative
    assert_in_delta(-0.005, dilution[:contribution], 1e-9)
    assert_equal "Net dilution / buybacks", dilution[:label]

    assert_equal :observable, bd.find { |c| c[:key] == "dividend_yield" }[:type]
    assert_equal :assumption, bd.find { |c| c[:key] == "real_earnings_growth" }[:type]

    # rows must sum to the headline number
    assert_in_delta cma.expected_real_return("equity_cn"), bd.sum { |c| c[:contribution] }, 1e-9
  end

  test "breakdown surfaces per-input source text, nil when absent" do
    bd = cma.breakdown("equity_cn")
    assert_equal "sample dividend source", bd.find { |c| c[:key] == "dividend_yield" }[:source]
    assert_nil bd.find { |c| c[:key] == "net_dilution" }[:source]
  end

  test "breakdown is empty for an unknown class" do
    assert_equal [], cma.breakdown("nope")
  end

  test "metadata returns the YAML metadata hash, or empty when absent" do
    # sample fixture has no metadata block
    assert_equal({}, cma.metadata)
  end
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `bin/rails test test/models/real_return/cma_test.rb`
Expected: FAIL — `NoMethodError: undefined method 'breakdown'` (and `metadata`).

- [ ] **Step 4: Refactor `cma.rb` to a single source of truth + add `breakdown`/`metadata`**

Replace the entire contents of `app/models/real_return/cma.rb` with:

```ruby
module RealReturn
  # Capital Market Assumptions: expected REAL return (neutral) and volatility per
  # asset class, from documented, editable building-block inputs (config/real_return/cma.yml).
  class Cma
    DEFAULT_PATH = Rails.root.join("config", "real_return", "cma.yml")

    # Display label + provenance type per building-block input. `type` is methodological
    # (independent of the stored numbers): :observable = anchored to market/index data,
    # :assumption = forward judgment. Nuance lives in the per-input source text.
    COMPONENTS = {
      "dividend_yield"       => { label: "Dividend yield",          type: :observable },
      "net_dilution"         => { label: "Net dilution / buybacks", type: :observable },
      "real_earnings_growth" => { label: "Real earnings growth",    type: :assumption },
      "valuation_reversion"  => { label: "Valuation reversion",     type: :assumption },
      "net_rental_yield"     => { label: "Net rental yield",        type: :observable },
      "real_rent_growth"     => { label: "Real rent growth",        type: :assumption },
      "real_yield"           => { label: "Real yield",              type: :observable },
      "real_rate"            => { label: "Real rate",               type: :observable },
      "real_return"          => { label: "Real return",             type: :assumption }
    }.freeze

    def initialize(path: DEFAULT_PATH)
      @path = path
    end

    def asset_classes
      data.keys
    end

    # Expected real return for `asset_class`, summed from its building blocks. nil if unknown.
    def expected_real_return(asset_class)
      cs = contributions(asset_class)
      return nil if cs.nil?

      cs.sum(0.0) { |_key, value| value }
    end

    # Ordered, decorated building blocks whose contributions sum to expected_real_return:
    # [{ key:, label:, type:, contribution:, source: }]. Empty for an unknown class.
    def breakdown(asset_class)
      cs = contributions(asset_class)
      return [] if cs.nil?

      a = data[asset_class.to_s]
      cs.map do |key, value|
        meta = COMPONENTS[key] || { label: key, type: :assumption }
        { key: key, label: meta[:label], type: meta[:type], contribution: value, source: a.dig("sources", key) }
      end
    end

    # Annualized volatility (σ) for `asset_class`, or nil if unknown.
    def sigma(asset_class)
      a = data[asset_class.to_s]
      a && a["sigma"]&.to_f
    end

    # Raw building-block inputs for an asset class (Hash with string keys), or nil.
    def components(asset_class)
      data[asset_class.to_s]
    end

    # File-level metadata (approach, as_of, sources), or {} if absent.
    def metadata
      data["metadata"] || {}
    end

    private
      # The formula as data: ordered [component_key, signed_contribution]. nil if class unknown.
      # SINGLE SOURCE OF TRUTH — expected_real_return sums it, breakdown decorates it, so the
      # displayed rows always add up to the headline number. net_dilution is SUBTRACTED.
      def contributions(asset_class)
        a = data[asset_class.to_s]
        return nil if a.nil?

        case a["kind"]
        when "equity"
          [ [ "dividend_yield", a["dividend_yield"].to_f ],
            [ "net_dilution", -a["net_dilution"].to_f ],
            [ "real_earnings_growth", a["real_earnings_growth"].to_f ],
            [ "valuation_reversion", a["valuation_reversion"].to_f ] ]
        when "real_estate"
          [ [ "net_rental_yield", a["net_rental_yield"].to_f ],
            [ "real_rent_growth", a["real_rent_growth"].to_f ],
            [ "valuation_reversion", a["valuation_reversion"].to_f ] ]
        when "bond" then [ [ "real_yield", a["real_yield"].to_f ] ]
        when "cash" then [ [ "real_rate", a["real_rate"].to_f ] ]
        else             [ [ "real_return", a["real_return"].to_f ] ]
        end
      end

      def data
        @data ||= YAML.safe_load(File.read(@path), permitted_classes: [], permitted_symbols: [], aliases: true)
      end
  end
end
```

- [ ] **Step 5: Run tests to verify they pass (incl. the unchanged existing ones)**

Run: `bin/rails test test/models/real_return/cma_test.rb`
Expected: PASS — all tests, including the pre-existing `expected_real_return` sum tests (behavior is identical: 0.045, 0.010, 0.004, −0.003, 0.000, 0.010).

- [ ] **Step 6: Commit**

```bash
git add app/models/real_return/cma.rb test/models/real_return/cma_test.rb test/fixtures/files/real_return/cma.sample.yml
git commit -m "$(cat <<'EOF'
feat(real_return): Cma#breakdown + single-source contributions + metadata

Decompose each CMA class into signed building-block contributions that sum to
expected_real_return, decorated with label / observable-vs-assumption type / source.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: `PortfolioComparison#referenced_asset_classes`

**Files:**
- Modify: `app/models/real_return/portfolio_comparison.rb`
- Test: `test/models/real_return/portfolio_comparison_test.rb`

- [ ] **Step 1: Write the failing test**

Append to `test/models/real_return/portfolio_comparison_test.rb` (inside the class):

```ruby
  test "referenced_asset_classes unions held holdings with every model-portfolio class" do
    comp = RealReturn::PortfolioComparison.new(family_with_property, as_of: Date.new(2024, 1, 1),
      horizon: 10, cma: cma, paths: 500, seed: 9)
    classes = comp.referenced_asset_classes

    # held: only a property -> real_estate_cn; presets add equity / bonds / gold / cash
    assert_includes classes, "real_estate_cn"
    assert_includes classes, "equity_cn"
    assert_includes classes, "govbond"
    assert_includes classes, "gold"
    assert_includes classes, "deposit"
    assert_equal classes, classes.uniq
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/models/real_return/portfolio_comparison_test.rb`
Expected: FAIL — `NoMethodError: undefined method 'referenced_asset_classes'`.

- [ ] **Step 3: Memoize the projection and add the method**

In `app/models/real_return/portfolio_comparison.rb`, change `rows` to use a memoized `projection`, and add the public method + private memo. Replace the `rows` method and the `private` section so it reads:

```ruby
    def rows
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

    # Ordered, de-duped CMA classes referenced by ANY row (Current's holdings + presets + custom),
    # so every expected-return number shown on the page has a traceable formula. Cheap: no Monte Carlo.
    def referenced_asset_classes
      held = projection.assets.map { |a| a[:asset_class] }
      preset = ModelPortfolio::PRESETS.values.flat_map { |w| ModelPortfolio.resolved(w, @currency, @cma).map { |x| x[:klass] } }
      custom = @custom_weights ? ModelPortfolio.resolved(@custom_weights, @currency, @cma).map { |x| x[:klass] } : []
      (held + preset + custom).uniq
    end

    private
      def projection
        @projection ||= Projection.new(@family, as_of: @as_of, cma: @cma, reference_data: @reference_data,
                                       correlation: @correlation, paths: @paths, seed: @seed)
      end

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
```

(The only change to `rows` is that the local `projection = Projection.new(...)` line is gone — it now calls the memoized `projection` method. `alternative_row`, `build_row`, `current_expected_return` are unchanged.)

- [ ] **Step 4: Run tests to verify they pass (incl. existing rows tests)**

Run: `bin/rails test test/models/real_return/portfolio_comparison_test.rb`
Expected: PASS — new test plus the three existing `rows`/`expected_real_return` tests.

- [ ] **Step 5: Commit**

```bash
git add app/models/real_return/portfolio_comparison.rb test/models/real_return/portfolio_comparison_test.rb
git commit -m "$(cat <<'EOF'
feat(real_return): PortfolioComparison#referenced_asset_classes

Union of held + model-portfolio classes so every comparison number is traceable.
Memoize the internal projection so rows and the union share one instance.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Enrich `config/real_return/cma.yml` with structured per-input `sources:`

**Files:**
- Modify: `config/real_return/cma.yml`

No new test — values are unchanged, so `cma_bundled_test.rb` (which checks ER finiteness/σ on the real config) guards this. This task only restructures the existing `source:` strings / `#` comments into a per-input `sources:` map.

- [ ] **Step 1: For each asset class, replace the single `source:` string with a `sources:` map**

Edit `config/real_return/cma.yml`. Keep every numeric value, `kind`, `sigma`, and the top `metadata` block unchanged. For each class, delete its `source:` line and add a `sources:` map keyed by the component(s) used by that `kind`. Use this exact text (lifted from the existing comments — assumptions stay labeled "assumption"):

```yaml
equity_cn:
  kind: equity
  dividend_yield: 0.028
  net_dilution: 0.010
  real_earnings_growth: 0.035
  valuation_reversion: 0.000
  sigma: 0.24
  sources:
    dividend_yield: "CSI 300 trailing dividend yield (~2.5–3%)"
    net_dilution: "net share issuance drag (~1%/yr, A-share supply)"
    real_earnings_growth: "assumption: China real earnings ~ real GDP (~4–5%) less leakage"
    valuation_reversion: "CSI 300 valuations near/below long-run average → ~no drag"

equity_us:
  kind: equity
  dividend_yield: 0.013
  net_dilution: -0.005
  real_earnings_growth: 0.025
  valuation_reversion: -0.015
  sigma: 0.16
  sources:
    dividend_yield: "S&P 500 trailing dividend yield (~1.3%)"
    net_dilution: "net buybacks add ~0.5%/yr (negative dilution)"
    real_earnings_growth: "assumption: US real earnings ~2–2.5%"
    valuation_reversion: "elevated CAPE (~33 vs ~17–20) → negative drag over horizon"

real_estate_cn:
  kind: real_estate
  net_rental_yield: 0.016
  real_rent_growth: 0.000
  valuation_reversion: -0.010
  sigma: 0.09
  sources:
    net_rental_yield: "China net rental yield / cap rate (~1.5–2%)"
    real_rent_growth: "assumption: weak (demographics, oversupply)"
    valuation_reversion: "elevated price/rent; BIS CN index correcting since 2021"

real_estate_us:
  kind: real_estate
  net_rental_yield: 0.035
  real_rent_growth: 0.005
  valuation_reversion: -0.005
  sigma: 0.07
  sources:
    net_rental_yield: "US net cap rate (~3.5–4%)"
    real_rent_growth: "assumption: modest real rent growth"
    valuation_reversion: "mildly elevated → small drag"

gold:
  kind: gold
  real_return: 0.000
  sigma: 0.16
  sources:
    real_return: "Erb & Harvey golden constant (NBER): gold long-run real ≈ 0"

govbond:
  kind: bond
  real_yield: 0.010
  sigma: 0.06
  sources:
    real_yield: "CN ~10y yield (~2.5%) − expected inflation (~1.5%) ≈ 1% real"

deposit:
  kind: cash
  real_rate: -0.005
  sigma: 0.01
  sources:
    real_rate: "CN 1y deposit (~1.5%) − expected inflation (~2%) ≈ −0.5% real"

crypto:
  kind: other
  real_return: 0.020
  sigma: 0.70
  sources:
    real_return: "assumption — speculative; very wide uncertainty"

other:
  kind: other
  real_return: 0.005
  sigma: 0.05
  sources:
    real_return: "assumption for mixed/managed products"
```

Keep the existing top-of-file `metadata:` block (with `approach`, `as_of: "2026-05-31"`, `sources`) exactly as-is.

- [ ] **Step 2: Verify the real config still loads and sums correctly**

Run: `bin/rails test test/models/real_return/cma_bundled_test.rb`
Expected: PASS — all 9 required classes load with finite ER in [−10%, 20%] and positive σ.

- [ ] **Step 3: Commit**

```bash
git add config/real_return/cma.yml
git commit -m "$(cat <<'EOF'
data(real_return): structured per-input sources in cma.yml

Restructure each class's source string into a sources: map keyed by input,
so the methodology panel can show provenance per building block. Values unchanged.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Controller — expose `@methodology_classes`

**Files:**
- Modify: `app/controllers/projections_controller.rb:23-26`

- [ ] **Step 1: Keep the comparison instance and read the referenced classes**

In `app/controllers/projections_controller.rb`, replace the block that builds `@comparison` (currently lines 23-26):

```ruby
    @comparison = RealReturn::PortfolioComparison.new(
      Current.family, as_of: Date.current, horizon: @horizon, annual_contribution: @contribution,
      custom_weights: @custom_weights
    ).rows
```

with:

```ruby
    comparison = RealReturn::PortfolioComparison.new(
      Current.family, as_of: Date.current, horizon: @horizon, annual_contribution: @contribution,
      custom_weights: @custom_weights
    )
    @comparison = comparison.rows
    @methodology_classes = comparison.referenced_asset_classes
```

- [ ] **Step 2: Verify the existing controller test still passes**

Run: `bin/rails test test/controllers/real_returns_controller_test.rb test/controllers`
Expected: PASS (no projections controller test asserts on the new ivar; this confirms nothing broke). If a projections controller test exists, it must still pass.

- [ ] **Step 3: Commit**

```bash
git add app/controllers/projections_controller.rb
git commit -m "$(cat <<'EOF'
feat(real_return): expose @methodology_classes to the projection view

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: Helper — `projection_signed_pct`

**Files:**
- Modify: `app/helpers/projections_helper.rb`
- Test: `test/helpers/projections_helper_test.rb`

- [ ] **Step 1: Write the failing test**

Append to `test/helpers/projections_helper_test.rb` (inside the class):

```ruby
  test "signed pct prefixes + / − (U+2212) and shows zero unsigned" do
    assert_equal "+2.8%", projection_signed_pct(0.028)
    assert_equal "−1.0%", projection_signed_pct(-0.010)
    assert_equal "0.0%", projection_signed_pct(0.0)
  end
```

(The `−` in `"−1.0%"` is U+2212 MINUS SIGN — the same glyph used elsewhere in this module.)

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/helpers/projections_helper_test.rb`
Expected: FAIL — `NoMethodError: undefined method 'projection_signed_pct'`.

- [ ] **Step 3: Add the helper**

In `app/helpers/projections_helper.rb`, add this method inside the module (e.g. right after `projection_asset_classes`):

```ruby
  # Signed percent of a building block's contribution: "+2.8%", "−1.0%", "0.0%".
  # Uses U+2212 MINUS SIGN to match the rest of the module.
  def projection_signed_pct(value)
    v = (value.to_f * 100).round(1)
    sign = v.positive? ? "+" : (v.negative? ? "−" : "")
    "#{sign}#{v.abs}%"
  end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bin/rails test test/helpers/projections_helper_test.rb`
Expected: PASS (the new test; the existing `projection_formula` tests still pass — they're removed in Task 7).

- [ ] **Step 5: Commit**

```bash
git add app/helpers/projections_helper.rb test/helpers/projections_helper_test.rb
git commit -m "$(cat <<'EOF'
feat(real_return): projection_signed_pct helper for building-block contributions

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: View — collapsible breakdown methodology panel

**Files:**
- Modify: `app/views/projections/show.html.erb:121-147`

- [ ] **Step 1: Replace the methodology panel**

In `app/views/projections/show.html.erb`, replace the entire methodology `<div>` (the block starting at the `<%# 5. Methodology / formulas (traceable) %>` comment through its closing `</div>`, currently lines 121-147) with:

```erb
  <%# 5. Methodology / formulas (traceable) %>
  <div class="bg-container rounded-xl border border-secondary shadow-xs p-5">
    <h2 class="text-lg font-medium text-primary mb-1">Methodology — every number is traceable</h2>
    <p class="text-sm text-secondary mb-1">Forward expected real returns are built block-by-block (editable in <code>config/real_return/cma.yml</code>).</p>
    <% if @cma.metadata["as_of"].present? %>
      <p class="text-xs text-subdued mb-2">As of <%= @cma.metadata["as_of"] %>. <%= @cma.metadata["approach"] %></p>
    <% end %>
    <p class="text-xs text-secondary mb-3">
      <span class="text-primary">●</span> Anchored to data
      <span class="ml-3 text-subdued">○</span> Assumption (judgment)
    </p>

    <div class="space-y-2 mb-4">
      <% @methodology_classes.each do |klass| %>
        <details class="border border-secondary rounded-lg">
          <summary class="flex justify-between items-center gap-2 px-3 py-2 cursor-pointer text-sm">
            <span class="text-primary font-medium"><%= klass %></span>
            <span class="text-secondary"><%= rr_pct_yr(@cma.expected_real_return(klass)) %> · σ <%= number_to_percentage((@cma.sigma(klass) || 0) * 100, precision: 0) %></span>
          </summary>
          <div class="px-3 pb-3 overflow-x-auto">
            <table class="w-full text-sm">
              <thead>
                <tr class="text-secondary text-left border-b border-secondary">
                  <th class="py-1 pr-4 font-medium">Input</th>
                  <th class="py-1 pr-4 font-medium">Contribution</th>
                  <th class="py-1 pr-4 font-medium">Type</th>
                  <th class="py-1 font-medium">Source / anchor</th>
                </tr>
              </thead>
              <tbody>
                <% @cma.breakdown(klass).each do |c| %>
                  <tr class="border-b border-secondary">
                    <td class="py-1 pr-4 text-primary align-top"><%= c[:label] %></td>
                    <td class="py-1 pr-4 text-secondary align-top whitespace-nowrap"><%= projection_signed_pct(c[:contribution]) %></td>
                    <td class="py-1 pr-4 align-top whitespace-nowrap">
                      <% if c[:type] == :observable %>
                        <span class="text-primary">● Anchored</span>
                      <% else %>
                        <span class="text-subdued">○ Assumption</span>
                      <% end %>
                    </td>
                    <td class="py-1 text-secondary align-top"><%= c[:source] || "—" %></td>
                  </tr>
                <% end %>
                <tr>
                  <td class="py-1 pr-4 text-primary font-medium">= Expected real return</td>
                  <td class="py-1 pr-4 text-primary font-medium whitespace-nowrap"><%= rr_pct_yr(@cma.expected_real_return(klass)) %></td>
                  <td></td>
                  <td></td>
                </tr>
              </tbody>
            </table>
          </div>
        </details>
      <% end %>
    </div>

    <div class="text-sm text-secondary space-y-1">
      <p><span class="text-primary font-medium">Monte Carlo:</span> each asset's annual real return ~ correlated lognormal (mean = expected real return, vol = σ); 5,000 paths; bands are the 15th / 50th / 85th percentiles. Parameters: correlation ρ = 0.25, horizon <%= @horizon %>y, annual savings <%= rr_money(@contribution, currency) %>, fixed RNG seed (reproducible).</p>
      <p><span class="text-primary font-medium">Real terms:</span> real = (1 + nominal) ÷ (1 + inflation) − 1 (Fisher). All values are today's purchasing power.</p>
    </div>
  </div>
```

- [ ] **Step 2: Lint the ERB**

Run: `bundle exec erb_lint ./app/views/projections/show.html.erb -a`
Expected: no remaining offenses (auto-corrects whitespace if any).

- [ ] **Step 3: Commit**

```bash
git add app/views/projections/show.html.erb
git commit -m "$(cat <<'EOF'
feat(real_return): per-input provenance breakdown in projection methodology panel

Collapsible <details> per asset class over the page-referenced union: each input's
signed contribution, anchored-vs-assumption tag, and source. Closes the equity/gold
traceability gap from the Compare-portfolios table.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 7: Remove the now-dead `projection_formula`

**Files:**
- Modify: `app/helpers/projections_helper.rb` (remove `projection_formula`)
- Modify: `test/helpers/projections_helper_test.rb` (remove its two tests)

- [ ] **Step 1: Confirm `projection_formula` has no remaining references**

Run: `grep -rn "projection_formula" app test`
Expected: only its definition (`app/helpers/projections_helper.rb`) and its two tests (`test/helpers/projections_helper_test.rb`). If anything else references it, stop and reconcile.

- [ ] **Step 2: Delete the helper method**

In `app/helpers/projections_helper.rb`, delete the entire `projection_formula` method (the comment line `# Human, traceable building-block formula ...` through its closing `end`, currently lines 40-64).

- [ ] **Step 3: Delete its two tests**

In `test/helpers/projections_helper_test.rb`, delete both the `"formula renders the building-block arithmetic for an equity class"` and `"formula handles bond / cash / gold kinds"` tests. Keep the fan-svg test and the `projection_signed_pct` test.

- [ ] **Step 4: Run the helper tests**

Run: `bin/rails test test/helpers/projections_helper_test.rb`
Expected: PASS — fan-svg + signed-pct tests; no reference to the removed method.

- [ ] **Step 5: Commit**

```bash
git add app/helpers/projections_helper.rb test/helpers/projections_helper_test.rb
git commit -m "$(cat <<'EOF'
refactor(real_return): drop projection_formula superseded by the breakdown panel

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 8: Full verification

**Files:** none (verification only)

- [ ] **Step 1: Run the full test suite**

Run: `bin/rails test`
Expected: all green. Pay attention to `test/models/real_return/*` and `test/helpers/projections_helper_test.rb`.

- [ ] **Step 2: Ruby lint**

Run: `bin/rubocop -f github -a`
Expected: no offenses (auto-corrects style).

- [ ] **Step 3: ERB lint**

Run: `bundle exec erb_lint ./app/**/*.erb -a`
Expected: no offenses.

- [ ] **Step 4: Security scan**

Run: `bin/brakeman --no-pager`
Expected: no new warnings.

- [ ] **Step 5: Manual preview verification**

Using the preview tools, load `/projection` for a CNY family that holds property/cash/other (no equity, no gold). Verify the Methodology panel now lists collapsible rows including `equity_cn`, `govbond`, and `gold`; expand `real_estate_cn` and confirm: rows show signed contributions that sum to the headline (e.g. `+1.6% / +0.0% / −1.0% = 0.6%/yr`), each row tagged ● Anchored or ○ Assumption, and the source column populated for anchored inputs. Take a screenshot for the user.

- [ ] **Step 6: Final commit (only if lint/auto-correct changed files)**

```bash
git add -A
git commit -m "$(cat <<'EOF'
chore(real_return): lint autocorrections for methodology provenance panel

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Self-Review

**Spec coverage:**
- "Missing rows" gap → Tasks 2 + 4 + 6 (`referenced_asset_classes` → `@methodology_classes` → view loop). ✓
- "No provenance" gap → Tasks 1 + 3 + 6 (`breakdown` w/ type + source; `sources:` in YAML; rendered with badges). ✓
- Signed contributions (rows sum to total; kills double-negative) → Task 1 `contributions`, Task 5 helper, Task 6 view. ✓
- Honesty tags (observable vs assumption) → Task 1 `COMPONENTS`, Task 6 badges. ✓
- Non-goal: no value changes → Task 3 keeps numbers; `cma_bundled_test` guards. ✓
- Edge case (start_value ≤ 0 still lists presets) → `referenced_asset_classes` includes presets unconditionally. ✓
- Retire `projection_formula` → Task 7. ✓

**Placeholder scan:** No TBD/TODO; every code/test step has complete code and exact run commands. ✓

**Type consistency:** `breakdown` returns `{ key:, label:, type:, contribution:, source: }` (Task 1) — consumed identically in the view (`c[:label]`, `c[:contribution]`, `c[:type] == :observable`, `c[:source]`) (Task 6). `referenced_asset_classes` returns string class keys (Task 2) — iterated as `klass` and passed to `@cma.breakdown`/`expected_real_return`/`sigma` (Task 6). `projection_signed_pct` takes a Float fraction, returns String (Tasks 5, 6). `metadata` returns a Hash (Task 1), read as `@cma.metadata["as_of"]`/`["approach"]` (Task 6). ✓
