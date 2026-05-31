# RealReturn CMA Core (P-A) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Provide forward-looking **expected real returns** (neutral) and **volatilities** per asset class via the chain-structured building-block method, plus an `Account → asset-class` mapping — the foundation the Monte-Carlo projection (P-B) will consume.

**Architecture:** `RealReturn::Cma` reads `config/real_return/cma.yml` (per asset class: the 4-layer building-block components + σ) and computes each class's expected real return by summing its components per kind (equity = div yield − dilution + real growth + valuation reversion; real estate = net rental yield + real rent growth + reversion; bond = real yield; cash = real rate; gold/other = stated real). `RealReturn::AssetClass` maps an `Account` to a class key using the family's region. The numbers are documented, editable **assumptions** anchored to observable inputs (not historical fabrication).

**Tech Stack:** Ruby 3.4.4 / Rails 7.2, Minitest + fixtures, existing `RealReturn::Region`, `YAML.safe_load`.

**Depends on:** `RealReturn::Region` (exists). Independent of P-0/P-B otherwise.

**Conventions:** Run from `/Users/clintongao/coding/maybe`; if `ruby -v` ≠ 3.4.4 prefix `export PATH="$HOME/.rbenv/shims:$PATH"; `. Tests: `bin/rails test <path>`.

---

## File Structure

| File | Responsibility |
|---|---|
| `app/models/real_return/asset_class.rb` (create) | `RealReturn::AssetClass.for(account, currency:)` → class key |
| `app/models/real_return/cma.rb` (create) | `RealReturn::Cma` — expected real return (building-block) + σ per class |
| `config/real_return/cma.yml` (create) | Researched per-class building-block inputs + σ + sources |
| `test/fixtures/files/real_return/cma.sample.yml` (create) | Synthetic CMA inputs for tests |
| `test/models/real_return/{asset_class,cma}_test.rb` (create) | Tests |

---

## Task 1: `RealReturn::AssetClass`

**Files:** Create `app/models/real_return/asset_class.rb`; Test `test/models/real_return/asset_class_test.rb`

- [ ] **Step 1: Write the failing test.** Create `test/models/real_return/asset_class_test.rb`:

```ruby
require "test_helper"

class RealReturn::AssetClassTest < ActiveSupport::TestCase
  # Lightweight stand-in for an Account (only accountable_type is read).
  Acct = Struct.new(:accountable_type)

  test "maps accountable types to class keys using the family region" do
    assert_equal "real_estate_cn", RealReturn::AssetClass.for(Acct.new("Property"), currency: "CNY")
    assert_equal "equity_cn", RealReturn::AssetClass.for(Acct.new("Investment"), currency: "CNY")
    assert_equal "real_estate_us", RealReturn::AssetClass.for(Acct.new("Property"), currency: "USD")
    assert_equal "equity_us", RealReturn::AssetClass.for(Acct.new("Investment"), currency: "USD")
  end

  test "non-regional classes ignore region" do
    assert_equal "crypto", RealReturn::AssetClass.for(Acct.new("Crypto"), currency: "CNY")
    assert_equal "deposit", RealReturn::AssetClass.for(Acct.new("Depository"), currency: "CNY")
    assert_equal "other", RealReturn::AssetClass.for(Acct.new("OtherAsset"), currency: "CNY")
    assert_equal "other", RealReturn::AssetClass.for(Acct.new("Vehicle"), currency: "USD")
  end
end
```

- [ ] **Step 2: Run it → fails** (`uninitialized constant RealReturn::AssetClass`): `bin/rails test test/models/real_return/asset_class_test.rb`

- [ ] **Step 3: Implement.** Create `app/models/real_return/asset_class.rb`:

```ruby
module RealReturn
  # Maps an Account to a CMA asset-class key. Equities and real estate are
  # region-suffixed by the family's currency (CNY -> _cn, else _us).
  module AssetClass
    module_function

    def for(account, currency:)
      region = Region.real_estate(currency).downcase # "cn" / "us"
      case account.accountable_type
      when "Property"   then "real_estate_#{region}"
      when "Investment" then "equity_#{region}"
      when "Crypto"     then "crypto"
      when "Depository" then "deposit"
      else                   "other" # OtherAsset, Vehicle, etc.
      end
    end
  end
end
```

- [ ] **Step 4: Run it → passes** (2 runs, 0 failures): `bin/rails test test/models/real_return/asset_class_test.rb`

- [ ] **Step 5: Commit**

```bash
git add app/models/real_return/asset_class.rb test/models/real_return/asset_class_test.rb
git commit -m "feat(real_return): add AssetClass account->class mapping

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: `RealReturn::Cma`

**Files:** Create `app/models/real_return/cma.rb`; Create `test/fixtures/files/real_return/cma.sample.yml`; Test `test/models/real_return/cma_test.rb`

- [ ] **Step 1: Create the synthetic CMA fixture.** Create `test/fixtures/files/real_return/cma.sample.yml`:

```yaml
equity_cn:
  kind: equity
  dividend_yield: 0.025
  net_dilution: 0.005
  real_earnings_growth: 0.030
  valuation_reversion: -0.005
  sigma: 0.20
real_estate_cn:
  kind: real_estate
  net_rental_yield: 0.018
  real_rent_growth: 0.005
  valuation_reversion: -0.013
  sigma: 0.10
govbond:
  kind: bond
  real_yield: 0.004
  sigma: 0.06
deposit:
  kind: cash
  real_rate: -0.003
  sigma: 0.01
gold:
  kind: gold
  real_return: 0.000
  sigma: 0.15
other:
  kind: other
  real_return: 0.010
  sigma: 0.05
```

- [ ] **Step 2: Write the failing test.** Create `test/models/real_return/cma_test.rb`:

```ruby
require "test_helper"

class RealReturn::CmaTest < ActiveSupport::TestCase
  def cma
    RealReturn::Cma.new(path: Rails.root.join("test", "fixtures", "files", "real_return", "cma.sample.yml"))
  end

  test "equity expected real return sums the building blocks" do
    # 0.025 - 0.005 + 0.030 + (-0.005) = 0.045
    assert_in_delta 0.045, cma.expected_real_return("equity_cn"), 1e-9
  end

  test "real estate expected real return sums its building blocks" do
    # 0.018 + 0.005 + (-0.013) = 0.010
    assert_in_delta 0.010, cma.expected_real_return("real_estate_cn"), 1e-9
  end

  test "bond / cash / gold / other use their direct real figures" do
    assert_in_delta 0.004, cma.expected_real_return("govbond"), 1e-9
    assert_in_delta(-0.003, cma.expected_real_return("deposit"), 1e-9)
    assert_in_delta 0.000, cma.expected_real_return("gold"), 1e-9
    assert_in_delta 0.010, cma.expected_real_return("other"), 1e-9
  end

  test "sigma and asset_classes are exposed; unknown class is nil" do
    assert_in_delta 0.20, cma.sigma("equity_cn"), 1e-9
    assert_includes cma.asset_classes, "gold"
    assert_nil cma.expected_real_return("nope")
    assert_nil cma.sigma("nope")
  end
end
```

- [ ] **Step 3: Run it → fails** (`uninitialized constant RealReturn::Cma`): `bin/rails test test/models/real_return/cma_test.rb`

- [ ] **Step 4: Implement.** Create `app/models/real_return/cma.rb`:

```ruby
module RealReturn
  # Capital Market Assumptions: expected REAL return (neutral) and volatility per
  # asset class, from documented, editable building-block inputs (config/real_return/cma.yml).
  class Cma
    DEFAULT_PATH = Rails.root.join("config", "real_return", "cma.yml")

    def initialize(path: DEFAULT_PATH)
      @path = path
    end

    def asset_classes
      data.keys
    end

    # Expected real return for `asset_class`, summed from its building blocks. nil if unknown.
    def expected_real_return(asset_class)
      a = data[asset_class.to_s]
      return nil if a.nil?

      case a["kind"]
      when "equity"
        a["dividend_yield"].to_f - a["net_dilution"].to_f + a["real_earnings_growth"].to_f + a["valuation_reversion"].to_f
      when "real_estate"
        a["net_rental_yield"].to_f + a["real_rent_growth"].to_f + a["valuation_reversion"].to_f
      when "bond"
        a["real_yield"].to_f
      when "cash"
        a["real_rate"].to_f
      else # gold, other
        a["real_return"].to_f
      end
    end

    # Annualized volatility (σ) for `asset_class`, or nil if unknown.
    def sigma(asset_class)
      a = data[asset_class.to_s]
      a && a["sigma"]&.to_f
    end

    private
      def data
        @data ||= YAML.safe_load(File.read(@path), permitted_classes: [], permitted_symbols: [], aliases: true)
      end
  end
end
```

- [ ] **Step 5: Run it → passes** (4 runs, 0 failures): `bin/rails test test/models/real_return/cma_test.rb`

- [ ] **Step 6: Commit**

```bash
git add app/models/real_return/cma.rb test/fixtures/files/real_return/cma.sample.yml test/models/real_return/cma_test.rb
git commit -m "feat(real_return): add Cma building-block expected-return engine

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: Real `config/real_return/cma.yml` (researched assumptions)

**This task is controller-executed** (research + curate the assumption inputs, anchored to observable public data, with `source` notes). The subagent step only adds the **smoke test**.

**Required shape** — every class carries the building-block components for its `kind` + `sigma` + a `source` note. Classes to include: `equity_cn`, `equity_us`, `real_estate_cn`, `real_estate_us`, `gold`, `govbond`, `deposit`, `crypto`, `other`.

```yaml
metadata:
  approach: "Chain-structured building blocks (Grinold-Kroner for equities; net rental yield + real growth + reversion for real estate; real yield for bonds; deposit real rate; golden-constant ~0 for gold). Forward-looking ASSUMPTIONS anchored to observable inputs; editable."
  as_of: "2026-05-31"
equity_cn:
  kind: equity
  dividend_yield: <current CSI 300 dividend yield>
  net_dilution: <share issuance drag>
  real_earnings_growth: <assumption, tied to China real GDP/productivity>
  valuation_reversion: <annualized ΔPE toward fair CAPE>
  sigma: <historical annual vol of CSI 300>
  source: "div yield: index data; growth: assumption; valuation: CAPE vs history (Damodaran/Shiller-style)"
# ... equity_us, real_estate_cn (cap rate + real rent growth + Price/Rent reversion),
#     real_estate_us, gold (real_return ~0, golden constant), govbond (real_yield = 10y yield - expected inflation),
#     deposit (real_rate = deposit rate - expected inflation), crypto (high sigma, modest/zero real assumption), other.
```

Sourcing notes the controller honors:
- σ per class: compute from the bundled historical annual series (`benchmarks.yml`) where available (sp500, csi300, gold, real_estate), else documented long-run vols.
- Equity inputs: current dividend yield (index data), real earnings growth (assumption tied to real GDP), valuation reversion (CAPE vs long-run; Damodaran ERP cross-check).
- Real estate: net rental yield / cap rate (public market data), real rent growth (assumption), Price/Rent reversion.
- Bonds/deposit: current yield/rate minus expected inflation → real.
- Gold: golden-constant ≈ 0 real (Erb-Harvey), with a small mean-reversion note.
- Every number has a `source`/rationale; all editable.

- [ ] **Step 1 (controller): write `config/real_return/cma.yml`** with researched values + sources for all nine classes.

- [ ] **Step 2: Write the smoke test.** Create `test/models/real_return/cma_bundled_test.rb`:

```ruby
require "test_helper"

class RealReturn::CmaBundledTest < ActiveSupport::TestCase
  setup { @cma = RealReturn::Cma.new } # default config/real_return/cma.yml

  REQUIRED = %w[equity_cn equity_us real_estate_cn real_estate_us gold govbond deposit crypto other].freeze

  test "all required asset classes load with a finite expected real return and positive sigma" do
    REQUIRED.each do |key|
      er = @cma.expected_real_return(key)
      assert er, "missing expected_real_return for #{key}"
      assert er.finite?, "#{key} expected real return not finite"
      assert er > -0.10 && er < 0.20, "#{key} expected real return #{er} out of a sane [-10%, 20%] band"
      assert @cma.sigma(key)&.positive?, "#{key} sigma must be positive"
    end
  end
end
```

- [ ] **Step 3: Run it** — `bin/rails test test/models/real_return/cma_bundled_test.rb` → 1 run, 0 failures.

- [ ] **Step 4: Commit**

```bash
git add config/real_return/cma.yml test/models/real_return/cma_bundled_test.rb
git commit -m "feat(real_return): bundle researched CMA assumptions (cma.yml)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Done criteria for P-A

- `bin/rails test test/models/real_return/` passes (incl. asset_class, cma, cma_bundled).
- `RealReturn::AssetClass.for` maps accounts to class keys; `RealReturn::Cma` returns a sane expected real return + σ for all nine classes from `cma.yml`.
- `cma.yml` documents every input with a `source`/rationale and is editable.

**Next:** P-B — `RealReturn::{Correlation, MonteCarlo, Projection}` consume `Cma` + `AssetClass` to simulate the basket forward under pess/neutral/opt scenarios.
