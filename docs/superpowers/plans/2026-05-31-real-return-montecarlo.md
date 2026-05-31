# RealReturn Monte Carlo + Projection (P-B) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Project the family's current asset basket forward N years under pessimistic / neutral / optimistic scenarios (Monte-Carlo percentile bands of **real** value), with optional annual savings.

**Architecture:** `RealReturn::Correlation` provides an equicorrelation matrix + its Cholesky factor. `RealReturn::MonteCarlo` simulates correlated lognormal annual **real** returns (mean = CMA expected real return, vol = σ) across many paths, injects annual contributions, and returns per-year value percentile bands; its RNG is seedable (deterministic tests + stable display). `RealReturn::Projection` (per `Family`) assembles the basket (current value + asset class + CMA inputs per in-scope account) and runs the simulation.

**Tech Stack:** Ruby 3.4.4 / Rails 7.2 (plain Ruby numerics — Cholesky + Box-Muller, no external libs), Minitest, existing `RealReturn::{Cma, AssetClass, Analysis, Region}`.

**Depends on:** P-A (`Cma`, `AssetClass`) + the engine/data already on `feature/real-return`.

**Conventions:** Run from `/Users/clintongao/coding/maybe`; if `ruby -v` ≠ 3.4.4 prefix `export PATH="$HOME/.rbenv/shims:$PATH"; `. Tests: `bin/rails test <path>`. All returns/values here are **real** (today's purchasing power); a nominal reference (real × (1+π)^t) is applied later in the UI (P-D). RNG uses Ruby's `Random.new(seed)` (this is app code, not a workflow script — `Random` is allowed).

---

## File Structure

| File | Responsibility |
|---|---|
| `app/models/real_return/correlation.rb` (create) | equicorrelation matrix + Cholesky factor |
| `app/models/real_return/monte_carlo.rb` (create) | correlated lognormal simulation → per-year percentile bands |
| `app/models/real_return/analysis.rb` (modify) | expose public `current_value` |
| `app/models/real_return/projection.rb` (create) | assemble basket from `Family`, run `MonteCarlo` |
| `test/models/real_return/{correlation,monte_carlo,projection}_test.rb` (create) | tests |

---

## Task 1: `RealReturn::Correlation`

**Files:** Create `app/models/real_return/correlation.rb`; Test `test/models/real_return/correlation_test.rb`

- [ ] **Step 1: Write the failing test.** Create `test/models/real_return/correlation_test.rb`:

```ruby
require "test_helper"

class RealReturn::CorrelationTest < ActiveSupport::TestCase
  test "matrix is equicorrelation: 1 on the diagonal, rho off-diagonal" do
    m = RealReturn::Correlation.new(rho: 0.3).matrix(3)
    assert_equal [ [ 1.0, 0.3, 0.3 ], [ 0.3, 1.0, 0.3 ], [ 0.3, 0.3, 1.0 ] ], m
  end

  test "cholesky factor reconstructs the matrix (L * L^T == matrix)" do
    corr = RealReturn::Correlation.new(rho: 0.25)
    n = 4
    l = corr.cholesky(n)
    m = corr.matrix(n)
    (0...n).each do |i|
      (0...n).each do |j|
        recon = (0...n).sum { |k| l[i][k] * l[j][k] }
        assert_in_delta m[i][j], recon, 1e-9, "L*L^T mismatch at #{i},#{j}"
      end
    end
  end

  test "cholesky of n=1 is [[1.0]]" do
    assert_equal [ [ 1.0 ] ], RealReturn::Correlation.new.cholesky(1)
  end
end
```

- [ ] **Step 2: Run it → fails** (`uninitialized constant RealReturn::Correlation`): `bin/rails test test/models/real_return/correlation_test.rb`

- [ ] **Step 3: Implement.** Create `app/models/real_return/correlation.rb`:

```ruby
module RealReturn
  # Cross-asset correlation as a single documented equicorrelation rho (1 on the
  # diagonal, rho off-diagonal). Always positive-semidefinite for rho in
  # [-1/(n-1), 1], so its Cholesky factor always exists. Pairwise-from-history
  # correlations are a future refinement.
  class Correlation
    DEFAULT_RHO = 0.25

    def initialize(rho: DEFAULT_RHO)
      @rho = rho
    end

    # n x n equicorrelation matrix (Array of Arrays of Float).
    def matrix(n)
      Array.new(n) do |i|
        Array.new(n) { |j| i == j ? 1.0 : @rho.to_f }
      end
    end

    # Lower-triangular Cholesky factor L of matrix(n), so L * L^T == matrix(n).
    def cholesky(n)
      a = matrix(n)
      l = Array.new(n) { Array.new(n, 0.0) }
      (0...n).each do |i|
        (0..i).each do |j|
          s = (0...j).sum { |k| l[i][k] * l[j][k] }
          l[i][j] = if i == j
            Math.sqrt([ a[i][i] - s, 0.0 ].max)
          else
            l[j][j].zero? ? 0.0 : (a[i][j] - s) / l[j][j]
          end
        end
      end
      l
    end
  end
end
```

- [ ] **Step 4: Run it → passes** (3 runs, 0 failures): `bin/rails test test/models/real_return/correlation_test.rb`

- [ ] **Step 5: Commit**

```bash
git add app/models/real_return/correlation.rb test/models/real_return/correlation_test.rb
git commit -m "feat(real_return): add Correlation (equicorrelation + Cholesky)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: `RealReturn::MonteCarlo`

**Files:** Create `app/models/real_return/monte_carlo.rb`; Test `test/models/real_return/monte_carlo_test.rb`

- [ ] **Step 1: Write the failing test.** Create `test/models/real_return/monte_carlo_test.rb`:

```ruby
require "test_helper"

class RealReturn::MonteCarloTest < ActiveSupport::TestCase
  def single_asset(er:, sigma:, value: 1000.0)
    RealReturn::MonteCarlo.new(
      assets: [ { value: value, expected_real_return: er, sigma: sigma } ],
      correlation: RealReturn::Correlation.new,
      horizon: 10, paths: 4000, seed: 42
    )
  end

  test "year 0 equals the starting basket value and bands are ordered" do
    out = single_asset(er: 0.05, sigma: 0.15).run
    assert_equal (0..10).to_a, out[:years]
    assert_in_delta 1000.0, out[:p50][0], 1e-9
    (0..10).each do |t|
      assert out[:p15][t] <= out[:p50][t], "p15 <= p50 at #{t}"
      assert out[:p50][t] <= out[:p85][t], "p50 <= p85 at #{t}"
    end
  end

  test "median tracks the analytic lognormal median" do
    out = single_asset(er: 0.05, sigma: 0.15).run
    # median value at T = value * exp(T * (ln(1+er) - sigma^2/2)); er=0.05, sigma=0.15, T=10
    m = Math.log(1.05) - 0.5 * 0.15**2
    analytic = 1000.0 * Math.exp(10 * m) # ~1456
    assert_in_delta analytic, out[:p50][10], analytic * 0.08 # within 8%
  end

  test "annual contributions raise the terminal median" do
    base = single_asset(er: 0.04, sigma: 0.12).run[:p50][10]
    with_contrib = RealReturn::MonteCarlo.new(
      assets: [ { value: 1000.0, expected_real_return: 0.04, sigma: 0.12 } ],
      correlation: RealReturn::Correlation.new,
      horizon: 10, annual_contribution: 100.0, paths: 4000, seed: 42
    ).run[:p50][10]
    assert with_contrib > base + 500, "contributions should lift terminal median materially"
  end

  test "deterministic for a fixed seed" do
    a = single_asset(er: 0.05, sigma: 0.15).run[:p50][10]
    b = single_asset(er: 0.05, sigma: 0.15).run[:p50][10]
    assert_equal a, b
  end
end
```

- [ ] **Step 2: Run it → fails** (`uninitialized constant RealReturn::MonteCarlo`): `bin/rails test test/models/real_return/monte_carlo_test.rb`

- [ ] **Step 3: Implement.** Create `app/models/real_return/monte_carlo.rb`:

```ruby
module RealReturn
  # Monte-Carlo projection of a basket's REAL value. Each asset's annual real return
  # is correlated-lognormal: log(1+r_i) ~ N(m_i, sigma_i), with m_i set so E[1+r_i] = 1+mu_i,
  # and correlation applied via the Cholesky factor of the correlation matrix.
  # Annual contributions are added each year, split across assets by current weight.
  class MonteCarlo
    # assets: Array of { value:, expected_real_return:, sigma: }
    def initialize(assets:, correlation:, horizon:, annual_contribution: 0.0, contribution_growth: 0.0, paths: 5000, seed: 123_456)
      @assets = assets
      @correlation = correlation
      @horizon = horizon
      @annual_contribution = annual_contribution.to_f
      @contribution_growth = contribution_growth.to_f
      @paths = paths
      @seed = seed
    end

    # => { years: [0..horizon], p15: [...], p50: [...], p85: [...] } of real basket value.
    def run
      n = @assets.size
      l = @correlation.cholesky(n)
      drift = @assets.map { |a| Math.log(1.0 + a[:expected_real_return].to_f) - 0.5 * a[:sigma].to_f**2 }
      vol = @assets.map { |a| a[:sigma].to_f }
      rng = Random.new(@seed)

      per_year = Array.new(@horizon + 1) { [] }
      @paths.times do
        values = @assets.map { |a| a[:value].to_f }
        contribution = @annual_contribution
        per_year[0] << values.sum
        (1..@horizon).each do |t|
          u = Array.new(n) { gaussian(rng) }
          values = Array.new(n) do |i|
            z = (0..i).sum { |k| l[i][k] * u[k] } # correlated normal for asset i
            values[i] * Math.exp(drift[i] + vol[i] * z)
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

    private
      # Standard normal via Box-Muller.
      def gaussian(rng)
        u1 = rng.rand
        u1 = 1e-12 if u1 <= 0.0
        u2 = rng.rand
        Math.sqrt(-2.0 * Math.log(u1)) * Math.cos(2.0 * Math::PI * u2)
      end

      def percentile(values, pct)
        sorted = values.sort
        idx = ((pct / 100.0) * (sorted.size - 1)).round
        sorted[idx]
      end
  end
end
```

- [ ] **Step 4: Run it → passes** (4 runs, 0 failures): `bin/rails test test/models/real_return/monte_carlo_test.rb`

- [ ] **Step 5: Commit**

```bash
git add app/models/real_return/monte_carlo.rb test/models/real_return/monte_carlo_test.rb
git commit -m "feat(real_return): add MonteCarlo (correlated lognormal real-value bands)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: `RealReturn::Projection` (+ expose `Analysis#current_value`)

**Files:** Modify `app/models/real_return/analysis.rb`; Create `app/models/real_return/projection.rb`; Test `test/models/real_return/projection_test.rb`

- [ ] **Step 1: Write the failing test.** Create `test/models/real_return/projection_test.rb`:

```ruby
require "test_helper"

class RealReturn::ProjectionTest < ActiveSupport::TestCase
  include LedgerTestingHelper

  def cma
    RealReturn::Cma.new(path: Rails.root.join("test", "fixtures", "files", "real_return", "cma.sample.yml"))
  end

  test "assembles in-scope accounts into assets with CMA inputs" do
    family = families(:empty)
    family.update!(currency: "CNY")
    create_account_with_ledger(
      account: { type: Property, currency: "CNY", balance: 0 },
      entries: [
        { type: "opening_anchor", date: Date.new(2010, 1, 1), balance: 1_000_000 },
        { type: "current_anchor", date: Date.new(2024, 1, 1), balance: 2_000_000 }
      ]
    )
    projection = RealReturn::Projection.new(family, as_of: Date.new(2024, 1, 1), cma: cma)

    assets = projection.assets
    assert_equal 1, assets.size
    a = assets.first
    assert_equal "real_estate_cn", a[:asset_class]
    assert_in_delta 2_000_000.0, a[:value], 1.0
    assert a[:expected_real_return] # from cma.sample real_estate_cn
    assert a[:sigma]
  end

  test "project returns ordered real bands starting at current basket value" do
    family = families(:empty)
    family.update!(currency: "CNY")
    create_account_with_ledger(
      account: { type: Property, currency: "CNY", balance: 0 },
      entries: [
        { type: "opening_anchor", date: Date.new(2010, 1, 1), balance: 1_000_000 },
        { type: "current_anchor", date: Date.new(2024, 1, 1), balance: 2_000_000 }
      ]
    )
    projection = RealReturn::Projection.new(family, as_of: Date.new(2024, 1, 1), cma: cma, paths: 2000, seed: 7)

    out = projection.project(horizon: 20)
    assert_equal (0..20).to_a, out[:years]
    assert_in_delta 2_000_000.0, out[:p50][0], 1.0
    assert out[:p15][20] <= out[:p50][20]
    assert out[:p50][20] <= out[:p85][20]
  end

  test "empty family projects an empty basket gracefully" do
    out = RealReturn::Projection.new(families(:empty), as_of: Date.current, cma: cma).project(horizon: 10)
    assert_equal Array.new(11, 0.0), out[:p50]
  end
end
```

- [ ] **Step 2: Run it → fails** (`uninitialized constant RealReturn::Projection` / `current_value`): `bin/rails test test/models/real_return/projection_test.rb`

- [ ] **Step 3: Expose `current_value` on Analysis.** In `app/models/real_return/analysis.rb`, add this PUBLIC method (place it right after the `has_data?` method, before `nominal_return`):

```ruby
    # Current value of this account in base currency (the projection's starting point). nil if none.
    def current_value
      terminal_value
    end
```

(`terminal_value` is an existing private method that returns the account's current value in base currency.)

- [ ] **Step 4: Implement Projection.** Create `app/models/real_return/projection.rb`:

```ruby
module RealReturn
  # Projects a family's in-scope asset basket forward via Monte Carlo (real terms).
  class Projection
    def initialize(family, as_of: Date.current, cma: Cma.new, reference_data: ReferenceData.default,
                   correlation: Correlation.new, paths: 5000, seed: 123_456)
      @family = family
      @as_of = as_of
      @base_currency = family.currency
      @cma = cma
      @reference_data = reference_data
      @correlation = correlation
      @paths = paths
      @seed = seed
    end

    # Array of { value:, asset_class:, expected_real_return:, sigma: } for in-scope accounts with data.
    def assets
      @assets ||= @family.accounts.visible.where(accountable_type: Analysis::IN_SCOPE).filter_map do |account|
        analysis = Analysis.new(account, as_of: @as_of, base_currency: @base_currency, reference_data: @reference_data)
        value = analysis.current_value
        next nil if value.nil? || value <= 0

        klass = AssetClass.for(account, currency: @base_currency)
        er = @cma.expected_real_return(klass)
        sigma = @cma.sigma(klass)
        next nil if er.nil? || sigma.nil?

        { value: value, asset_class: klass, expected_real_return: er, sigma: sigma }
      end
    end

    # => { years:, p15:, p50:, p85: } of real basket value over [0, horizon].
    def project(horizon:, annual_contribution: 0.0, contribution_growth: 0.0)
      list = assets
      return empty_result(horizon) if list.empty?

      MonteCarlo.new(
        assets: list, correlation: @correlation, horizon: horizon,
        annual_contribution: annual_contribution, contribution_growth: contribution_growth,
        paths: @paths, seed: @seed
      ).run
    end

    private
      def empty_result(horizon)
        zeros = Array.new(horizon + 1, 0.0)
        { years: (0..horizon).to_a, p15: zeros, p50: zeros.dup, p85: zeros.dup }
      end
  end
end
```

- [ ] **Step 5: Run it → passes** (3 runs, 0 failures): `bin/rails test test/models/real_return/projection_test.rb`

- [ ] **Step 6: Run the whole suite + rubocop:**

```bash
bin/rails test test/models/real_return/
bin/rubocop app/models/real_return/
```
Expected: all green; no offenses.

- [ ] **Step 7: Commit**

```bash
git add app/models/real_return/analysis.rb app/models/real_return/projection.rb test/models/real_return/projection_test.rb
git commit -m "feat(real_return): add Projection (basket assembly + Monte Carlo run)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Done criteria for P-B

- `bin/rails test test/models/real_return/` passes (incl. correlation, monte_carlo, projection).
- `RealReturn::Projection.new(family).project(horizon:, annual_contribution:)` returns ordered real-value percentile bands (p15 ≤ p50 ≤ p85) starting at the current basket value, deterministic for a fixed seed, empty-family-safe.

**Next:** P-C — `RealReturn::WealthTier` + researched `wealth_distribution.yml` (CN + global) to place current and projected net worth on the wealth distribution. Then P-D — the projection page (fan chart + terminal cards + social tier + assumption-chain panel) with the new left-nav button.
