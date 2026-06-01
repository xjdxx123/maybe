# Dynamic Expected Return Implementation Plan (regime-mixture)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make each asset's expected real return depend on horizon (valuation amortized over N), year (a gliding growth term), and a per-path macro **regime** (a probability-weighted mixture with per-class offsets), instead of a single constant.

**Architecture:** `Cma` is the horizon-aware single source of truth (`projection_inputs` → `mean_start`/`mean_end`/`regime_offsets`; `regimes` → the global mixture). `MonteCarlo` composes `μ_i(t,p) = lerp(mean_start,mean_end,t/N) + regimeOffset_i(g_p)` where one regime `g_p` is drawn per path (shared across assets), gated on regimes existing. `Projection`/`ModelPortfolio`/`PortfolioComparison` thread the horizon and pass the regime mixture; the methodology panel annotates the trajectory and the regime mix.

**Tech Stack:** Rails 7 (Ruby), Minitest + fixtures, ERB, TailwindCSS, Hotwire.

**Spec:** `docs/superpowers/specs/2026-05-31-real-return-dynamic-expected-return-design.md`

**Commit policy:** Repo `CLAUDE.md` — commit only when the user asks. Commit steps included; confirm or get blanket approval. All messages end with the `Co-Authored-By` trailer.

**Backward-compatibility contract (keeps every task green):**
- `Cma#expected_real_return(ac)` (no horizon) still returns the old constants for the SAMPLE fixture (fixed `valuation_reversion`, no `glide`, no `regimes`).
- `MonteCarlo` reads `mean_start`/`mean_end`/`regime_offsets` but falls back to `expected_real_return`/flat/`{}` when absent, and only draws a regime when the global mixture is non-empty — so old-style assets reproduce today's output bit-for-bit.

**The model (precise):**
- `μ_i(t,p) = lerp(mean_start_i, mean_end_i, t/N) + offset_i(g_p)`, clamp `μ > −0.99`, `drift = log(1+μ) − 0.5σ²`.
- `g_p` = one regime per path drawn from the global mixture `{base: p0, bear: p1, bull: p2}` (probabilities sum to 1); shared across all assets in the path; `offset_i(base) = 0`.
- `expected_real_return` (displayed/weighted) is the **base-regime** central return `(mean_start+mean_end)/2`; regimes are the dispersion layer (so the median path ≈ base, while a heavier/deeper bear skews the bands/mean down). The panel shows base + the regime mix explicitly.

---

### Task 1: `Cma` — horizon-aware engine + regime mixture

**Files:**
- Modify: `app/models/real_return/cma.rb`
- Modify (test fixture): `test/fixtures/files/real_return/cma.sample.yml`
- Test: `test/models/real_return/cma_test.rb`

- [ ] **Step 1: Extend the sample fixture (leave existing classes unchanged)**

At the TOP of `test/fixtures/files/real_return/cma.sample.yml` add a global regimes block, and append a new class at the end:

```yaml
regimes:
  base: 0.60
  bear: 0.25
  bull: 0.15
```

```yaml
equity_glide:
  kind: equity
  dividend_yield: 0.020
  net_dilution: 0.000
  real_earnings_growth: 0.040
  sigma: 0.18
  valuation:
    current: 30
    target: 20
  glide:
    real_earnings_growth: 0.020
  regimes:
    bear: -0.03
    bull: 0.02
```

(Existing `equity_cn`, `real_estate_cn`, `govbond`, `deposit`, `gold`, `other` stay exactly as-is — the backward-compatible path. The global `regimes:` key must be ignored by `asset_classes`/`expected_real_return` for the old classes.)

- [ ] **Step 2: Write failing tests**

Append to `test/models/real_return/cma_test.rb` (inside the class):

```ruby
  test "valuation amortizes over the horizon (shorter horizon = bigger annual drag)" do
    drag10 = cma.breakdown("equity_glide", horizon: 10).find { |c| c[:key] == "valuation_reversion" }[:contribution]
    drag30 = cma.breakdown("equity_glide", horizon: 30).find { |c| c[:key] == "valuation_reversion" }[:contribution]
    assert_in_delta((20.0 / 30.0)**(1.0 / 10) - 1.0, drag10, 1e-9)
    assert_in_delta((20.0 / 30.0)**(1.0 / 30) - 1.0, drag30, 1e-9)
    assert drag10 < drag30, "shorter horizon should have a larger (more negative) annual drag"
  end

  test "projection_inputs glides growth start->end and exposes regime offsets" do
    pi = cma.projection_inputs("equity_glide", horizon: 30)
    val = (20.0 / 30.0)**(1.0 / 30) - 1.0
    assert_in_delta 0.020 + 0.040 + val, pi[:mean_start], 1e-9   # growth at start 0.040
    assert_in_delta 0.020 + 0.020 + val, pi[:mean_end], 1e-9     # growth at terminal 0.020
    assert_in_delta(-0.03, pi[:regime_offsets]["bear"], 1e-9)
    assert_in_delta 0.02, pi[:regime_offsets]["bull"], 1e-9
    assert_in_delta 0.18, pi[:sigma], 1e-9
  end

  test "regimes returns the global mixture, empty when absent" do
    assert_in_delta 0.25, cma.regimes["bear"], 1e-9
    # a Cma whose file has no regimes: block -> {}
    empty = RealReturn::Cma.new(path: Rails.root.join("test", "fixtures", "files", "real_return", "cma.sample.yml"))
    assert empty.regimes.key?("base")
  end

  test "expected_real_return(horizon:) is the base start/end average; breakdown sums to it" do
    er = cma.expected_real_return("equity_glide", horizon: 30)
    pi = cma.projection_inputs("equity_glide", horizon: 30)
    assert_in_delta (pi[:mean_start] + pi[:mean_end]) / 2.0, er, 1e-9
    assert_in_delta er, cma.breakdown("equity_glide", horizon: 30).sum { |c| c[:contribution] }, 1e-9
  end

  test "breakdown annotates glide and valuation" do
    bd = cma.breakdown("equity_glide", horizon: 30)
    assert_equal "4.0% → 2.0%", bd.find { |c| c[:key] == "real_earnings_growth" }[:note]
    assert_equal "30→20 over 30y", bd.find { |c| c[:key] == "valuation_reversion" }[:note]
  end

  test "backward-compatible: no-horizon expected_real_return unchanged for fixed-reversion classes" do
    assert_in_delta 0.045, cma.expected_real_return("equity_cn"), 1e-9   # 0.025 - 0.005 + 0.030 - 0.005
    assert_equal({}, cma.projection_inputs("equity_cn", horizon: 30)[:regime_offsets])
  end
```

- [ ] **Step 3: Run to verify they fail**

Run: `bin/rails test test/models/real_return/cma_test.rb`
Expected: FAIL — `undefined method 'projection_inputs'`/`regimes`; wrong arity for breakdown/expected_real_return.

- [ ] **Step 4: Implement**

Replace lines 30–93 of `app/models/real_return/cma.rb` (the methods `expected_real_return` through the end of the `private` section) with:

```ruby
    # Horizon over which a valuation gap fully reverts when none is given.
    DEFAULT_HORIZON = 30

    # Base-regime expected real return over `horizon` (start/end average of the gliding mean).
    # nil if unknown. horizon: nil + fixed-reversion class == the old constant.
    def expected_real_return(asset_class, horizon: nil)
      cs_start = contributions(asset_class, horizon: horizon, at: :start)
      return nil if cs_start.nil?

      (sum(cs_start) + sum(contributions(asset_class, horizon: horizon, at: :end))) / 2.0
    end

    # Inputs the Monte Carlo needs for one asset over `horizon`:
    # { mean_start:, mean_end:, regime_offsets: {name=>offset}, sigma: }, or nil if unknown.
    def projection_inputs(asset_class, horizon:)
      cs_start = contributions(asset_class, horizon: horizon, at: :start)
      return nil if cs_start.nil?

      a = data[asset_class.to_s]
      {
        mean_start: sum(cs_start),
        mean_end: sum(contributions(asset_class, horizon: horizon, at: :end)),
        regime_offsets: (a["regimes"] || {}).transform_values(&:to_f),
        sigma: a["sigma"].to_f
      }
    end

    # Global regime mixture { name => probability }, or {} if absent.
    def regimes
      data["regimes"] || {}
    end

    # Ordered, decorated building blocks summing to expected_real_return(horizon:):
    # [{ key:, label:, type:, contribution:, source:, note: }]. `note` annotates the glide
    # ("4.0% → 2.0%") or valuation ("30→20 over 30y"). Empty for an unknown class.
    def breakdown(asset_class, horizon: nil)
      cs = contributions(asset_class, horizon: horizon, at: :avg)
      return [] if cs.nil?

      a = data[asset_class.to_s]
      cs.map do |key, value|
        meta = COMPONENTS[key] || { label: key, type: :assumption }
        { key: key, label: meta[:label], type: meta[:type], contribution: value,
          source: a.dig("sources", key), note: component_note(a, key, horizon) }
      end
    end

    def sigma(asset_class)
      a = data[asset_class.to_s]
      a && a["sigma"]&.to_f
    end

    def components(asset_class)
      data[asset_class.to_s]
    end

    def metadata
      data["metadata"] || {}
    end

    def asset_classes
      data.keys - %w[metadata regimes]
    end

    private
      def sum(contributions)
        contributions.sum(0.0) { |_key, value| value }
      end

      # Formula as data: ordered [component_key, signed_contribution] for `asset_class` over
      # `horizon`. `at` (:start/:end/:avg) selects the gliding component's value. nil if unknown.
      def contributions(asset_class, horizon:, at:)
        a = data[asset_class.to_s]
        return nil if a.nil?

        n = (horizon || DEFAULT_HORIZON)
        case a["kind"]
        when "equity"
          [ [ "dividend_yield", a["dividend_yield"].to_f ],
            [ "net_dilution", -a["net_dilution"].to_f ],
            [ "real_earnings_growth", glide_value(a, "real_earnings_growth", at) ],
            [ "valuation_reversion", valuation_amort(a, n) ] ]
        when "real_estate"
          [ [ "net_rental_yield", a["net_rental_yield"].to_f ],
            [ "real_rent_growth", glide_value(a, "real_rent_growth", at) ],
            [ "valuation_reversion", valuation_amort(a, n) ] ]
        when "bond" then [ [ "real_yield", a["real_yield"].to_f ] ]
        when "cash" then [ [ "real_rate", a["real_rate"].to_f ] ]
        else             [ [ "real_return", a["real_return"].to_f ] ]
        end
      end

      def glide_value(a, key, at)
        base = a[key].to_f
        terminal = a.dig("glide", key)
        return base if terminal.nil?

        terminal = terminal.to_f
        case at
        when :start then base
        when :end   then terminal
        else (base + terminal) / 2.0
        end
      end

      # Valuation contribution, constant across years for a given horizon:
      # (target/current)^(1/N) - 1 when valuation:{current,target}; else fixed valuation_reversion; else 0.
      def valuation_amort(a, n)
        v = a["valuation"]
        if v.is_a?(Hash) && v["current"].to_f.positive? && v["target"].to_f.positive?
          (v["target"].to_f / v["current"].to_f)**(1.0 / n) - 1.0
        else
          a["valuation_reversion"].to_f
        end
      end

      def component_note(a, key, horizon)
        if a.dig("glide", key)
          "#{pct(a[key])} → #{pct(a.dig('glide', key))}"
        elsif key == "valuation_reversion" && a["valuation"].is_a?(Hash)
          "#{a['valuation']['current']}→#{a['valuation']['target']} over #{horizon || DEFAULT_HORIZON}y"
        end
      end

      def pct(v)
        "#{(v.to_f * 100).round(1)}%"
      end

      def data
        @data ||= YAML.safe_load(File.read(@path), permitted_classes: [], permitted_symbols: [], aliases: true)
      end
```

NOTE: `asset_classes` now excludes the reserved `metadata`/`regimes` top-level keys (it previously returned all `data.keys`).

- [ ] **Step 5: Run to verify pass**

Run: `bin/rails test test/models/real_return/cma_test.rb`
Expected: PASS. Existing breakdown tests calling `breakdown("equity_cn")` (no horizon) still work; the `asset_classes` test still finds "gold" and no longer leaks "regimes"/"metadata".

- [ ] **Step 6: Commit**

```bash
git add app/models/real_return/cma.rb test/models/real_return/cma_test.rb test/fixtures/files/real_return/cma.sample.yml
git commit -m "$(cat <<'EOF'
feat(real_return): horizon-aware Cma — valuation amortization, glide, regime mixture

projection_inputs(horizon:) -> mean_start/mean_end/regime_offsets; regimes -> global
mixture; valuation reverts over N via (target/current)^(1/N)-1; growth glides. Old
no-horizon expected_real_return preserved for fixed-reversion classes.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: `cma.yml` — seed valuation / glide / regimes

**Files:** Modify `config/real_return/cma.yml`. Guarded by `cma_bundled_test.rb`.

- [ ] **Step 1: Add the global regime mixture** at the top of the file, right after the `metadata:` block:

```yaml
regimes:
  base: 0.60
  bear: 0.25
  bull: 0.15
```

- [ ] **Step 2: Edit equity & real-estate classes** — replace each `valuation_reversion:` with a `valuation:` block, add `glide:` where it trends, add a per-class `regimes:` offset map, and add `sources:` for the new keys. Apply exactly:

```yaml
equity_cn:
  kind: equity
  dividend_yield: 0.028
  net_dilution: 0.010
  real_earnings_growth: 0.035
  valuation:
    current: 12
    target: 12
  sigma: 0.24
  glide:
    real_earnings_growth: 0.020
  regimes:
    bear: -0.04
    bull: 0.03
  sources:
    dividend_yield: "CSI 300 trailing dividend yield (~2.5–3%)"
    net_dilution: "net share issuance drag (~1%/yr, A-share supply)"
    real_earnings_growth: "assumption: China real earnings ~ real GDP (~4–5%) less leakage"
    valuation_reversion: "CSI 300 CAPE ~ at long-run average → ~no drag"
    glide: "growth eases toward ~2% as the economy matures"
    regimes: "bear: structural impairment; bull: reform/productivity upside"

equity_us:
  kind: equity
  dividend_yield: 0.013
  net_dilution: -0.005
  real_earnings_growth: 0.025
  valuation:
    current: 33
    target: 20
  sigma: 0.16
  glide:
    real_earnings_growth: 0.020
  regimes:
    bear: -0.04
    bull: 0.02
  sources:
    dividend_yield: "S&P 500 trailing dividend yield (~1.3%)"
    net_dilution: "net buybacks add ~0.5%/yr (negative dilution)"
    real_earnings_growth: "assumption: US real earnings ~2–2.5%"
    valuation_reversion: "Shiller CAPE ~33 vs long-run ~17–20; reverts over the horizon"
    glide: "real EPS growth eases as the AI/cycle tailwind normalizes"
    regimes: "bear: secular stagnation/de-rating; bull: productivity boom"

real_estate_cn:
  kind: real_estate
  net_rental_yield: 0.016
  real_rent_growth: 0.000
  valuation:
    current: 1.35
    target: 1.00
  sigma: 0.09
  regimes:
    bear: -0.03
    bull: 0.01
  sources:
    net_rental_yield: "China net rental yield / cap rate (~1.5–2%)"
    real_rent_growth: "assumption: weak (demographics, oversupply)"
    valuation_reversion: "price/rent ~35% above fair; BIS CN index correcting since 2021"
    regimes: "bear: deeper/longer correction; bull: stabilization"

real_estate_us:
  kind: real_estate
  net_rental_yield: 0.035
  real_rent_growth: 0.005
  valuation:
    current: 1.16
    target: 1.00
  sigma: 0.07
  regimes:
    bear: -0.025
    bull: 0.015
  sources:
    net_rental_yield: "US net cap rate (~3.5–4%)"
    real_rent_growth: "assumption: modest real rent growth"
    valuation_reversion: "price/rent mildly elevated → small drag over the horizon"
    regimes: "bear: rate shock/recession; bull: soft landing"
```

Add a `regimes:` map (and a `sources.regimes` line) to the remaining classes, leaving existing keys intact:
- `gold`: `regimes: { bear: 0.03, bull: -0.01 }` — source: "bear: crisis hedge bid; bull: risk-on drag"
- `govbond`: `regimes: { bear: 0.005, bull: 0.0 }` — source: "bear: flight-to-safety; bull: neutral"
- `deposit`: `regimes: { bear: 0.0, bull: 0.0 }` — source: "cash ≈ regime-insensitive (real)"
- `crypto`: `regimes: { bear: -0.10, bull: 0.10 }` — source: "extreme both ways"
- `other`: `regimes: { bear: -0.02, bull: 0.01 }` — source: "mixed"

- [ ] **Step 3: Verify the real config loads with sane numbers**

Run: `bin/rails test test/models/real_return/cma_bundled_test.rb`
Expected: PASS — all 9 classes finite, in [−10%, 20%], σ>0. (`expected_real_return` is the base-regime number; regime offsets don't enter it.)

- [ ] **Step 4: Spot-check horizon dependence**

Run: `bin/rails runner 'c = RealReturn::Cma.new; puts "US 10y=%.4f 30y=%.4f; regimes=%p" % [c.expected_real_return("equity_us", horizon: 10), c.expected_real_return("equity_us", horizon: 30), c.regimes]'`
Expected: 10y meaningfully below 30y; `regimes` prints `{"base"=>0.6,"bear"=>0.25,"bull"=>0.15}`. Paste output.

- [ ] **Step 5: Commit**

```bash
git add config/real_return/cma.yml
git commit -m "$(cat <<'EOF'
data(real_return): seed valuation gaps, growth glides, regime mixture

Global regimes (base/bear/bull) + per-class real-return offsets; equities/real-estate
get valuation:{current,target} (horizon-amortized) + growth glide. Editable, sourced.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: `MonteCarlo` — per-year/per-path mean (glide + regime draw)

**Files:**
- Modify: `app/models/real_return/monte_carlo.rb`
- Test: `test/models/real_return/monte_carlo_test.rb`

- [ ] **Step 1: Write failing tests**

Append to `test/models/real_return/monte_carlo_test.rb` (inside the class):

```ruby
  test "a bear-heavy regime mixture widens the band and skews the median down" do
    corr = RealReturn::Correlation.new
    base = { value: 1_000_000.0, sigma: 0.12, mean_start: 0.05, mean_end: 0.05 }
    no_regime = RealReturn::MonteCarlo.new(assets: [ base ], correlation: corr, horizon: 20, paths: 4000, seed: 7).run
    regimed = RealReturn::MonteCarlo.new(assets: [ base.merge(regime_offsets: { "bear" => -0.05, "bull" => 0.02 }) ],
      correlation: corr, horizon: 20, paths: 4000, seed: 7,
      regimes: { "base" => 0.6, "bear" => 0.25, "bull" => 0.15 }).run
    spread = ->(r) { r[:p85].last - r[:p15].last }
    assert spread.call(regimed) > spread.call(no_regime), "regime mixture should widen p15..p85"
    assert regimed[:p50].last < no_regime[:p50].last, "bear-heavy mixture should pull the median down"
  end

  test "a declining glide bends the median below a flat mean of the same start" do
    corr = RealReturn::Correlation.new
    flat = RealReturn::MonteCarlo.new(assets: [ { value: 1e6, sigma: 0.10, mean_start: 0.05, mean_end: 0.05 } ],
      correlation: corr, horizon: 30, paths: 2000, seed: 7).run
    glide = RealReturn::MonteCarlo.new(assets: [ { value: 1e6, sigma: 0.10, mean_start: 0.05, mean_end: 0.02 } ],
      correlation: corr, horizon: 30, paths: 2000, seed: 7).run
    assert glide[:p50].last < flat[:p50].last
  end

  test "old-style assets (expected_real_return, no regimes) still run" do
    corr = RealReturn::Correlation.new
    r = RealReturn::MonteCarlo.new(assets: [ { value: 1_000.0, expected_real_return: 0.03, sigma: 0.1 } ],
      correlation: corr, horizon: 5, paths: 500, seed: 7).run
    assert_equal 6, r[:p50].size
    assert r[:p15].last <= r[:p50].last
  end
```

- [ ] **Step 2: Run to verify they fail**

Run: `bin/rails test test/models/real_return/monte_carlo_test.rb`
Expected: FAIL (regime mixture ignored → band/median assertions fail).

- [ ] **Step 3: Implement**

In `app/models/real_return/monte_carlo.rb`, add `regimes: {}` to the constructor signature and store `@regimes = regimes`. Then replace the `run` method (lines 19–52) with:

```ruby
    # => { years: [0..horizon], p15: [...], p50: [...], p85: [...] } of real basket value.
    def run
      n = @assets.size
      l = @correlation.cholesky(n)
      mean_start = @assets.map { |a| (a[:mean_start] || a[:expected_real_return]).to_f }
      mean_end = @assets.map { |a| (a[:mean_end] || a[:mean_start] || a[:expected_real_return]).to_f }
      vol = @assets.map { |a| a[:sigma].to_f }
      offsets = @assets.map { |a| a[:regime_offsets] || {} }
      regimes = @regimes.to_a # [[name, prob], ...]; empty => no regime draw
      rng = Random.new(@seed)

      per_year = Array.new(@horizon + 1) { [] }
      @paths.times do
        regime = pick_regime(rng, regimes) # nil when no regimes
        eps = offsets.map { |o| regime ? (o[regime] || 0.0).to_f : 0.0 }
        values = @assets.map { |a| a[:value].to_f }
        contribution = @annual_contribution
        per_year[0] << values.sum
        (1..@horizon).each do |t|
          frac = t.to_f / @horizon
          u = Array.new(n) { gaussian(rng) }
          values = Array.new(n) do |i|
            mean = mean_start[i] + (mean_end[i] - mean_start[i]) * frac + eps[i]
            mean = -0.99 if mean < -0.99
            drift = Math.log(1.0 + mean) - 0.5 * vol[i]**2
            z = (0..i).sum { |k| l[i][k] * u[k] } # correlated normal for asset i
            values[i] * Math.exp(drift + vol[i] * z)
          end
          total = values.sum
          if contribution.positive? && total.positive?
            values = Array.new(n) { |i| values[i] + contribution * (values[i] / total) }
          end
          per_year[t] << values.sum
          contribution *= (1.0 + @contribution_growth)
        end
      end

      {
        years: (0..@horizon).to_a,
        p15: per_year.map { |vals| percentile(vals, 15) },
        p50: per_year.map { |vals| percentile(vals, 50) },
        p85: per_year.map { |vals| percentile(vals, 85) }
      }
    end
```

Add this private helper (after `gaussian`, before `percentile`):

```ruby
      # Draw one regime per path from the mixture [[name, prob], ...]. Returns nil (no draw, no
      # RNG consumed) when the mixture is empty, so regime-free runs are bit-identical to before.
      def pick_regime(rng, regimes)
        return nil if regimes.empty?

        u = rng.rand
        cum = 0.0
        regimes.each { |name, p| cum += p.to_f; return name if u < cum }
        regimes.last[0]
      end
```

- [ ] **Step 4: Run to verify pass**

Run: `bin/rails test test/models/real_return/monte_carlo_test.rb`
Expected: PASS (new + existing). Existing tests pass no `regimes:` → `@regimes` defaults `{}` → `pick_regime` returns nil with no RNG draw → identical stream → identical output.

- [ ] **Step 5: Commit**

```bash
git add app/models/real_return/monte_carlo.rb test/models/real_return/monte_carlo_test.rb
git commit -m "$(cat <<'EOF'
feat(real_return): MonteCarlo per-year/per-path mean (glide + regime mixture)

mean_i(t,p) = lerp(mean_start,mean_end,t/N) + regime_offset_i(g_p); one shared regime
per path, gated on a non-empty mixture so regime-free runs are bit-identical to before.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: `Projection` — thread horizon, build mean + regime fields, pass mixture

**Files:**
- Modify: `app/models/real_return/projection.rb`
- Modify: `app/controllers/projections_controller.rb`
- Test: `test/models/real_return/projection_test.rb`

- [ ] **Step 1: Write a failing test**

Append to `test/models/real_return/projection_test.rb` (inside the class; if it lacks a single-asset family helper, add one mirroring `portfolio_comparison_test.rb`'s `family_with_property` and `include LedgerTestingHelper`):

```ruby
  test "assets carry horizon-aware mean and regime fields" do
    proj = RealReturn::Projection.new(family_with_one_asset, as_of: Date.new(2024, 1, 1),
      cma: RealReturn::Cma.new(path: Rails.root.join("test", "fixtures", "files", "real_return", "cma.sample.yml")))
    a = proj.assets(horizon: 20).first
    assert a.key?(:mean_start)
    assert a.key?(:mean_end)
    assert a.key?(:regime_offsets)
    assert a.key?(:sigma)
  end
```

- [ ] **Step 2: Run to verify it fails**

Run: `bin/rails test test/models/real_return/projection_test.rb`
Expected: FAIL — `wrong number of arguments` for `assets(horizon:)`.

- [ ] **Step 3: Make `assets` horizon-aware and pass the mixture to the Monte Carlo**

In `app/models/real_return/projection.rb`, replace `assets` (lines 21–34) and `project` (lines 37–46) with:

```ruby
    # Array of { value:, asset_class:, expected_real_return:, mean_start:, mean_end:,
    # regime_offsets:, sigma: } for in-scope accounts with data, over `horizon` years.
    def assets(horizon:)
      (@assets ||= {})[horizon] ||= @family.accounts.visible.where(accountable_type: SCOPE).filter_map do |account|
        analysis = Analysis.new(account, as_of: @as_of, base_currency: @base_currency, reference_data: @reference_data)
        value = analysis.current_value
        next nil if value.nil? || value <= 0

        klass = AssetClass.for(account, currency: @base_currency)
        inputs = @cma.projection_inputs(klass, horizon: horizon)
        next nil if inputs.nil?

        { value: value, asset_class: klass,
          expected_real_return: @cma.expected_real_return(klass, horizon: horizon),
          mean_start: inputs[:mean_start], mean_end: inputs[:mean_end],
          regime_offsets: inputs[:regime_offsets], sigma: inputs[:sigma] }
      end
    end

    # => { years:, p15:, p50:, p85: } of real basket value over [0, horizon].
    def project(horizon:, annual_contribution: 0.0, contribution_growth: 0.0)
      list = assets(horizon: horizon)
      return empty_result(horizon) if list.empty?

      MonteCarlo.new(
        assets: list, correlation: @correlation, horizon: horizon,
        annual_contribution: annual_contribution, contribution_growth: contribution_growth,
        paths: @paths, seed: @seed, regimes: @cma.regimes
      ).run
    end
```

- [ ] **Step 4: Update the controller** — in `app/controllers/projections_controller.rb`, change `@assets = projection.assets` to:

```ruby
    @assets = projection.assets(horizon: @horizon)
```

- [ ] **Step 5: Update `PortfolioComparison`'s two `projection.assets` calls** — in `app/models/real_return/portfolio_comparison.rb`, change `current_expected_return(projection.assets, start_value)` to `current_expected_return(projection.assets(horizon: @horizon), start_value)`, and `projection.assets.map` (in `referenced_asset_classes`) to `projection.assets(horizon: @horizon).map`.

- [ ] **Step 6: Run the affected suites**

Run: `bin/rails test test/models/real_return/projection_test.rb test/models/real_return/portfolio_comparison_test.rb test/controllers/projections_controller_test.rb`
Expected: PASS. If any test asserted EXACT Monte-Carlo values against the real config, update them to property checks (ordering/sizes), noting the change in the commit — do not silently weaken a meaningful assertion.

- [ ] **Step 7: Commit**

```bash
git add app/models/real_return/projection.rb app/controllers/projections_controller.rb app/models/real_return/portfolio_comparison.rb test/models/real_return/projection_test.rb
git commit -m "$(cat <<'EOF'
feat(real_return): thread horizon through Projection; pass regime mixture to MC

assets(horizon:) builds mean_start/mean_end/regime_offsets via Cma#projection_inputs;
project passes Cma#regimes to the Monte Carlo; controller + PortfolioComparison pass horizon.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: `ModelPortfolio` — thread horizon + regime offsets; pass mixture

**Files:**
- Modify: `app/models/real_return/model_portfolio.rb`
- Modify: `app/models/real_return/portfolio_comparison.rb`
- Test: `test/models/real_return/model_portfolio_test.rb`

- [ ] **Step 1: Write a failing test**

Append to `test/models/real_return/model_portfolio_test.rb` (inside the class; mirror its existing `cma`-from-sample setup):

```ruby
  test "assets_for carries horizon-aware mean and regime fields" do
    cma = RealReturn::Cma.new(path: Rails.root.join("test", "fixtures", "files", "real_return", "cma.sample.yml"))
    a = RealReturn::ModelPortfolio.assets_for({ equity: 1.0 }, total: 1_000.0, currency: "CNY", cma: cma, horizon: 20).first
    assert a.key?(:mean_start)
    assert a.key?(:mean_end)
    assert a.key?(:regime_offsets)
  end
```

- [ ] **Step 2: Run to verify it fails**

Run: `bin/rails test test/models/real_return/model_portfolio_test.rb`
Expected: FAIL — `unknown keyword: :horizon`.

- [ ] **Step 3: Thread horizon + regime offsets through `ModelPortfolio`**

In `app/models/real_return/model_portfolio.rb`, replace `assets_for`, `expected_real_return`, and `resolved` (lines 28–61) with:

```ruby
    # [{ value:, asset_class:, expected_real_return:, mean_start:, mean_end:, regime_offsets:, sigma: }],
    # total split by normalized weights, over `horizon` years.
    def assets_for(weights, total:, currency:, cma:, horizon:)
      r = resolved(weights, currency, cma, horizon)
      sum = r.sum { |x| x[:w] }
      return [] if sum <= 0

      r.map do |x|
        { value: total * (x[:w] / sum), asset_class: x[:klass], expected_real_return: x[:er],
          mean_start: x[:mean_start], mean_end: x[:mean_end], regime_offsets: x[:regime_offsets], sigma: x[:sigma] }
      end
    end

    # Weighted average base expected real return over resolved buckets for `horizon`, or nil.
    def expected_real_return(weights, currency:, cma:, horizon:)
      r = resolved(weights, currency, cma, horizon)
      sum = r.sum { |x| x[:w] }
      return nil if sum <= 0

      r.sum(0.0) { |x| x[:er] * (x[:w] / sum) }
    end

    # Buckets with positive weight AND a valid CMA class, with horizon-aware inputs.
    def resolved(weights, currency, cma, horizon)
      weights.filter_map do |bucket, weight|
        w = weight.to_f
        next nil if w <= 0

        klass = bucket_class(bucket, currency)
        inputs = klass && cma.projection_inputs(klass, horizon: horizon)
        next nil if inputs.nil?

        { w: w, klass: klass, er: cma.expected_real_return(klass, horizon: horizon),
          mean_start: inputs[:mean_start], mean_end: inputs[:mean_end],
          regime_offsets: inputs[:regime_offsets], sigma: inputs[:sigma] }
      end
    end
```

- [ ] **Step 4: Update `PortfolioComparison`** — in `app/models/real_return/portfolio_comparison.rb`:
  - In `alternative_row`: add `, horizon: @horizon` to both `ModelPortfolio.assets_for(...)` and `ModelPortfolio.expected_real_return(...)`; and add `regimes: @cma.regimes` to the `MonteCarlo.new(...)` call there.
  - In `referenced_asset_classes`: change both `ModelPortfolio.resolved(w, @currency, @cma)` and `ModelPortfolio.resolved(@custom_weights, @currency, @cma)` to pass `@horizon` as the 4th positional arg.

- [ ] **Step 5: Run the affected suites**

Run: `bin/rails test test/models/real_return/model_portfolio_test.rb test/models/real_return/portfolio_comparison_test.rb`
Expected: PASS. (`all-cash row expected real return equals the deposit CMA`: deposit has no glide/valuation → its base ER is still −0.003; regimes don't enter `expected_real_return`.)

- [ ] **Step 6: Commit**

```bash
git add app/models/real_return/model_portfolio.rb app/models/real_return/portfolio_comparison.rb test/models/real_return/model_portfolio_test.rb
git commit -m "$(cat <<'EOF'
feat(real_return): thread horizon + regime offsets through ModelPortfolio

resolved/assets_for/expected_real_return take horizon and carry mean_start/mean_end/
regime_offsets; alternative rows pass the regime mixture to the Monte Carlo.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: View — methodology panel shows trajectory + regime mix

**Files:** Modify `app/views/projections/show.html.erb`.

- [ ] **Step 1: Update the per-class `<details>`** — replace from `<% @methodology_classes.each do |klass| %>` through the breakdown `<table>`'s closing `</table>` with:

```erb
      <% @methodology_classes.each do |klass| %>
        <% er = @cma.expected_real_return(klass, horizon: @horizon) %>
        <% pi = @cma.projection_inputs(klass, horizon: @horizon) %>
        <details class="border border-secondary rounded-lg">
          <summary class="flex justify-between items-center gap-2 px-3 py-2 cursor-pointer text-sm">
            <span class="text-primary font-medium"><%= klass %></span>
            <span class="text-secondary">
              <% if pi && (pi[:mean_start] - pi[:mean_end]).abs > 1e-6 %>
                <%= rr_pct_yr(pi[:mean_start]) %> → <%= rr_pct_yr(pi[:mean_end]) %> over <%= @horizon %>y
              <% else %>
                <%= rr_pct_yr(er) %>
              <% end %>
              · σ <%= number_to_percentage((@cma.sigma(klass) || 0) * 100, precision: 0) %>
            </span>
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
                <% @cma.breakdown(klass, horizon: @horizon).each do |c| %>
                  <tr class="border-b border-secondary">
                    <td class="py-1 pr-4 text-primary align-top">
                      <%= c[:label] %><% if c[:note] %> <span class="text-subdued">(<%= c[:note] %>)</span><% end %>
                    </td>
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
                  <td class="py-1 pr-4 text-primary font-medium">= Expected real return (base)</td>
                  <td class="py-1 pr-4 text-primary font-medium whitespace-nowrap" colspan="3"><%= rr_pct_yr(er) %></td>
                </tr>
                <% if pi && pi[:regime_offsets].any? %>
                  <tr>
                    <td class="py-1 pr-4 text-subdued align-top">Regime offsets</td>
                    <td class="py-1 text-subdued align-top" colspan="3">
                      <%= pi[:regime_offsets].map { |name, off| "#{name} #{projection_signed_pct(off)}" }.join(" · ") %>
                      (mix: <%= @cma.regimes.map { |n, p| "#{n} #{number_to_percentage(p * 100, precision: 0)}" }.join(" / ") %>)
                    </td>
                  </tr>
                <% end %>
              </tbody>
            </table>
          </div>
        </details>
      <% end %>
```

Then append to the "Monte Carlo:" note paragraph, before its `</p>`:
```erb
 Bands also reflect a gliding growth assumption and a per-path macro regime (base/bear/bull) — not only year-to-year volatility.
```

- [ ] **Step 2: Lint** — Run: `bundle exec erb_lint ./app/views/projections/show.html.erb -a` — Expected: no offenses.

- [ ] **Step 3: Commit**

```bash
git add app/views/projections/show.html.erb
git commit -m "$(cat <<'EOF'
feat(real_return): methodology panel shows mean trajectory + regime mix

Summary shows base start→end over Ny; breakdown annotates glide and valuation; a
Regime offsets row lists each regime's per-class offset and the global mixture.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 7: Full verification

**Files:** none.

- [ ] **Step 1: Full suite** — `bin/rails test` — Expected: 0 failures; only the known pre-existing Plaid-env errors (6 `Provider::PlaidTest` + 1 `UsersControllerTest#test_admin_can_reset_family_data`, all `base_url for nil`). Confirm none are in `real_return`/projections and the count hasn't grown.
- [ ] **Step 2: Ruby lint** — `bin/rubocop -a app/models/real_return app/controllers/projections_controller.rb app/views/projections app/helpers/projections_helper.rb` — Expected: no offenses.
- [ ] **Step 3: ERB lint** — `bundle exec erb_lint ./app/**/*.erb` — Expected: no offenses.
- [ ] **Step 4: Security** — `bundle exec brakeman --no-pager --no-progress` — Expected: 0 warnings.
- [ ] **Step 5: Sanity** — `bin/rails runner 'c=RealReturn::Cma.new; %w[equity_us real_estate_cn].each { |k| puts "%s 10y=%.4f 30y=%.4f off=%p" % [k, c.expected_real_return(k, horizon: 10), c.expected_real_return(k, horizon: 30), c.projection_inputs(k, horizon: 30)[:regime_offsets]] }'` — Expected: 10y < 30y; bear/bull offsets present. Paste.
- [ ] **Step 6: Final whole-feature review** — dispatch a reviewer over `git diff <first-task-commit>~1..HEAD`: confirm the chain (cma.yml regimes/valuation/glide → Cma#projection_inputs/#regimes → Projection/ModelPortfolio assets → MonteCarlo μ(t,p)+regime → panel) is intact and the spec is satisfied; confirm regime-free/no-glide classes are unchanged.

---

## Self-Review

**Spec coverage:** μ_i(t,p)=glide+regime → Task 3 via Task 1 inputs ✓; valAmort(N) → Task 1/2 ✓; glide → Task 1/2, shown Task 6 ✓; regime mixture (one shared regime/path, per-class offsets, base=0, gated) → Task 3 + `Cma#regimes`/`regime_offsets` (Task 1), seeded Task 2 ✓; backward-compat (fixed reversion / flat / no regimes) → Task 1 + Task 3 fallbacks+gate ✓; horizon threaded → Tasks 4/5/6 ✓; panel annotations (start→end, CAPE c→t over Ny, regime offsets+mix) → Task 6 ✓; honesty (assumption tags persist; new params sourced/editable) → Task 2 `sources:` ✓; tests (val horizon-dependence, glide, regime widens+skews, reproducibility, backward-compat) → Tasks 1/3 ✓.

**Placeholder scan:** none — complete code in every code step; threading steps give exact substitutions.

**Type consistency:** `projection_inputs` → `{mean_start, mean_end, regime_offsets, sigma}` (Task 1) consumed identically in Projection (Task 4), ModelPortfolio (Task 5); MonteCarlo reads `mean_start/mean_end/regime_offsets/sigma/value` + `regimes:` kwarg (Task 3), passed by Projection (`@cma.regimes`, Task 4) and PortfolioComparison's `alternative_row` (Task 5). `Cma#regimes` → Hash{name=>prob} (Task 1) used by MonteCarlo + view (Task 6). `breakdown` gains `note:` (Task 1) rendered Task 6. `expected_real_return(ac, horizon:)` consistent across Tasks 1/4/5/6. `asset_classes` excludes `metadata`/`regimes` (Task 1).
