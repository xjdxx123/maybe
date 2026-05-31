# RealReturn Wealth Tier (P-C) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Place a (real, CNY) net worth on the **China national** and **global** adult-wealth distributions — returning a percentile + a tier label — so we can say where the basket sits today and where the projected basket would land.

**Architecture:** `RealReturn::WealthTier` reads `config/real_return/wealth_distribution.yml` (per region: ascending `[percentile, threshold_CNY]` points) and interpolates a percentile **log-linearly** in net worth (clamped at the ends), plus a tier label. The thresholds are researched, documented, and labeled approximate (wealth data is coarse).

**Tech Stack:** Ruby 3.4.4 / Rails 7.2, Minitest, `YAML.safe_load`. Pure PORO, no external deps.

**Depends on:** nothing in P-A/P-B (independent); consumed later by P-D (the projection page) to show current + projected social tier.

**Conventions:** Run from `/Users/clintongao/coding/maybe`; if `ruby -v` ≠ 3.4.4 prefix `export PATH="$HOME/.rbenv/shims:$PATH"; `. Tests: `bin/rails test <path>`. Net worth is in the family base currency (CNY here), today's money; projected net worth is compared to **today's** distribution (apples-to-apples in today's money).

---

## File Structure

| File | Responsibility |
|---|---|
| `app/models/real_return/wealth_tier.rb` (create) | net worth → percentile + tier label, CN & global |
| `config/real_return/wealth_distribution.yml` (create) | researched CN + WLD `[pct, CNY threshold]` points |
| `test/fixtures/files/real_return/wealth_distribution.sample.yml` (create) | synthetic distribution for tests |
| `test/models/real_return/{wealth_tier,wealth_distribution_bundled}_test.rb` (create) | tests |

---

## Task 1: `RealReturn::WealthTier`

**Files:** Create `app/models/real_return/wealth_tier.rb`; Create `test/fixtures/files/real_return/wealth_distribution.sample.yml`; Test `test/models/real_return/wealth_tier_test.rb`

- [ ] **Step 1: Create the synthetic fixture.** Create `test/fixtures/files/real_return/wealth_distribution.sample.yml`:

```yaml
CN:
  - [50, 200000]
  - [90, 1000000]
  - [99, 8000000]
WLD:
  - [50, 60000]
  - [90, 1000000]
  - [99, 8000000]
```

- [ ] **Step 2: Write the failing test.** Create `test/models/real_return/wealth_tier_test.rb`:

```ruby
require "test_helper"

class RealReturn::WealthTierTest < ActiveSupport::TestCase
  def tier
    RealReturn::WealthTier.new(
      path: Rails.root.join("test", "fixtures", "files", "real_return", "wealth_distribution.sample.yml")
    )
  end

  test "percentile equals the listed percentile at an exact threshold" do
    assert_in_delta 90.0, tier.percentile(1_000_000, region: "CN"), 1e-6
    assert_in_delta 50.0, tier.percentile(200_000, region: "CN"), 1e-6
  end

  test "percentile interpolates log-linearly between thresholds" do
    # geometric midpoint of 200k and 1.0M = sqrt(2e11) ~= 447,214 -> midpoint percentile (50+90)/2 = 70
    assert_in_delta 70.0, tier.percentile(447_214, region: "CN"), 0.5
  end

  test "percentile clamps below the lowest and above the highest threshold" do
    assert_in_delta 50.0, tier.percentile(50_000, region: "CN"), 1e-6   # below lowest -> first pct
    assert_in_delta 99.0, tier.percentile(50_000_000, region: "CN"), 1e-6 # above highest -> last pct
  end

  test "tier_label buckets the percentile" do
    assert_equal "Top 1%", tier.tier_label(99.4)
    assert_equal "Top 10%", tier.tier_label(92.0)
    assert_equal "Above median", tier.tier_label(60.0)
    assert_equal "Below median", tier.tier_label(30.0)
  end

  test "placement returns CN and global percentile + label" do
    p = tier.placement(8_000_000)
    assert_in_delta 99.0, p[:cn][:percentile], 1e-6
    assert_equal "Top 1%", p[:cn][:label]
    assert p[:global][:percentile] >= 99.0
    assert_equal "Top 1%", p[:global][:label]
  end

  test "unknown region or non-positive net worth is nil" do
    assert_nil tier.percentile(1_000_000, region: "ZZ")
    assert_nil tier.percentile(0, region: "CN")
  end
end
```

- [ ] **Step 3: Run it → fails** (`uninitialized constant RealReturn::WealthTier`): `bin/rails test test/models/real_return/wealth_tier_test.rb`

- [ ] **Step 4: Implement.** Create `app/models/real_return/wealth_tier.rb`:

```ruby
module RealReturn
  # Places a net worth (base currency, today's money) on a wealth distribution and
  # returns a percentile (log-linear interpolation between [pct, threshold] points,
  # clamped at the ends) plus a tier label, for China national (CN) and global (WLD).
  class WealthTier
    DEFAULT_PATH = Rails.root.join("config", "real_return", "wealth_distribution.yml")

    def initialize(path: DEFAULT_PATH)
      @path = path
    end

    # Percentile (0-100) of `net_worth` within `region`'s distribution, or nil if unavailable.
    def percentile(net_worth, region:)
      points = series(region)
      return nil if points.nil? || points.empty? || net_worth <= 0

      return points.first[0] if net_worth <= points.first[1]
      return points.last[0] if net_worth >= points.last[1]

      points.each_cons(2) do |(p0, t0), (p1, t1)|
        next if net_worth > t1

        frac = (Math.log(net_worth) - Math.log(t0)) / (Math.log(t1) - Math.log(t0))
        return p0 + (p1 - p0) * frac
      end
      points.last[0]
    end

    # Human tier label from a percentile.
    def tier_label(pct)
      return nil if pct.nil?

      case
      when pct >= 99 then "Top 1%"
      when pct >= 95 then "Top 5%"
      when pct >= 90 then "Top 10%"
      when pct >= 75 then "Top 25%"
      when pct >= 50 then "Above median"
      else "Below median"
      end
    end

    # { cn: { percentile:, label: }, global: { percentile:, label: } }
    def placement(net_worth)
      { cn: tier_for(net_worth, "CN"), global: tier_for(net_worth, "WLD") }
    end

    private
      def tier_for(net_worth, region)
        pct = percentile(net_worth, region: region)
        { percentile: pct, label: tier_label(pct) }
      end

      # Ascending [percentile(Float), threshold(Float)] points for a region, or nil.
      def series(region)
        raw = data[region.to_s]
        return nil if raw.nil?

        raw.map { |pct, threshold| [ pct.to_f, threshold.to_f ] }.sort_by(&:last)
      end

      def data
        @data ||= YAML.safe_load(File.read(@path), permitted_classes: [], permitted_symbols: [], aliases: true)
      end
  end
end
```

- [ ] **Step 5: Run it → passes** (6 runs, 0 failures): `bin/rails test test/models/real_return/wealth_tier_test.rb`

- [ ] **Step 6: Commit**

```bash
git add app/models/real_return/wealth_tier.rb test/fixtures/files/real_return/wealth_distribution.sample.yml test/models/real_return/wealth_tier_test.rb
git commit -m "feat(real_return): add WealthTier (net worth -> CN/global percentile + label)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: Real `config/real_return/wealth_distribution.yml` (researched)

**This task is controller-executed** (research the distributions, convert to CNY today's money, document sources). The subagent step only adds the **smoke test**.

**Required shape** — per region (`CN`, `WLD`), ascending `[percentile, net-worth-threshold-in-CNY]` points; granular (10/25/50/75/90/95/99, optionally 99.9). Thresholds = adult net worth below which that percent of adults fall, in CNY (today's money).

```yaml
metadata:
  source: "Global: UBS/Credit Suisse Global Wealth Report (adult wealth percentiles). CN: Global Wealth Report China + CHFS (China Household Finance Survey). Converted to CNY at ~7.1 CNY/USD."
  as_of: "2024"
  note: "APPROXIMATE — wealth distributions are coarse and survey-based; treat as directional."
CN:
  - [10, <cny>]
  - [25, <cny>]
  - [50, <cny>]   # China median adult net worth
  - [75, <cny>]
  - [90, <cny>]
  - [95, <cny>]
  - [99, <cny>]
WLD:
  - [10, <cny>]
  - [25, <cny>]
  - [50, <cny>]   # global median adult net worth
  - [75, <cny>]
  - [90, <cny>]
  - [95, <cny>]
  - [99, <cny>]
```

- [ ] **Step 1 (controller): write `config/real_return/wealth_distribution.yml`** with researched CNY thresholds for CN + WLD + sources.

- [ ] **Step 2: Write the smoke test.** Create `test/models/real_return/wealth_distribution_bundled_test.rb`:

```ruby
require "test_helper"

class RealReturn::WealthDistributionBundledTest < ActiveSupport::TestCase
  setup { @tier = RealReturn::WealthTier.new } # default config/real_return/wealth_distribution.yml

  test "CN and WLD distributions load and rank wealth monotonically" do
    %w[CN WLD].each do |region|
      low = @tier.percentile(100_000, region: region)
      mid = @tier.percentile(2_000_000, region: region)
      high = @tier.percentile(50_000_000, region: region)
      assert low && mid && high, "missing distribution for #{region}"
      assert low <= mid && mid <= high, "#{region} percentile must rise with wealth"
      assert high >= 95, "#{region}: ¥50M should be high percentile"
    end
  end

  test "a large net worth lands in the top tier" do
    p = @tier.placement(37_200_000)
    assert_equal "Top 1%", p[:cn][:label]
    assert_equal "Top 1%", p[:global][:label]
  end
end
```

- [ ] **Step 3: Run it** — `bin/rails test test/models/real_return/wealth_distribution_bundled_test.rb` → 2 runs, 0 failures.

- [ ] **Step 4: Commit**

```bash
git add config/real_return/wealth_distribution.yml test/models/real_return/wealth_distribution_bundled_test.rb
git commit -m "feat(real_return): bundle researched wealth distribution (CN + global)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Done criteria for P-C

- `bin/rails test test/models/real_return/` passes (incl. wealth_tier, wealth_distribution_bundled).
- `RealReturn::WealthTier.new.placement(net_worth)` returns CN + global percentile + tier label; monotonic in wealth; clamps at the ends; the demo basket (¥37.2M) lands "Top 1%" both CN and global.

**Next:** P-D — the projection page: route + `ProjectionsController`, fan chart, terminal cards, the social-tier display (current + projected, CN & global via `WealthTier`), the editable assumption-chain panel, and the **Projection** left-nav button. Browser-verified.
