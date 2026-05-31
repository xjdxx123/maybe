require "test_helper"

class RealReturn::RegionTest < ActiveSupport::TestCase
  test "cpi_area maps known currencies and falls back to WLD" do
    assert_equal "CN", RealReturn::Region.cpi_area("CNY")
    assert_equal "US", RealReturn::Region.cpi_area("USD")
    assert_equal "WLD", RealReturn::Region.cpi_area("EUR")
  end

  test "real_estate region maps known currencies and falls back to US" do
    assert_equal "CN", RealReturn::Region.real_estate("CNY")
    assert_equal "US", RealReturn::Region.real_estate("JPY")
  end

  test "for_benchmark returns a region only for real_estate" do
    assert_equal "CN", RealReturn::Region.for_benchmark("real_estate", "CNY")
    assert_nil RealReturn::Region.for_benchmark("sp500", "CNY")
  end

  test "BENCHMARK_KEYS lists the six vehicles" do
    assert_equal %w[sp500 csi300 gold deposit govbond real_estate], RealReturn::Region::BENCHMARK_KEYS
  end
end
