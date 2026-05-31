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
      assert high >= 95, "#{region}: ¥50M should be a high percentile"
    end
  end

  test "a large net worth lands in the top tier" do
    p = @tier.placement(37_200_000)
    assert_equal "Top 1%", p[:cn][:label]
    assert_equal "Top 1%", p[:global][:label]
  end
end
