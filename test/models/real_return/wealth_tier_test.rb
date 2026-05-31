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
