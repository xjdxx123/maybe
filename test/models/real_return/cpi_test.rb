require "test_helper"

class RealReturn::CpiTest < ActiveSupport::TestCase
  setup do
    dir = Rails.root.join("test", "fixtures", "files", "real_return")
    data = RealReturn::ReferenceData::Bundled.new(
      cpi_path: dir.join("cpi.sample.yml"),
      benchmarks_path: dir.join("benchmarks.sample.yml")
    )
    @cpi = RealReturn::Cpi.new(reference_data: data)
  end

  test "annualized inflation over two years" do
    # CN 100 -> 110 over 730 days => 1.1**(365/730) - 1 ~= 0.04881
    rate = @cpi.annualized(area: "CN", from: Date.new(2010, 1, 1), to: Date.new(2012, 1, 1))
    assert_in_delta 0.04881, rate, 1e-4
  end

  test "real return deflates the nominal rate" do
    real = @cpi.real_return(nominal: 0.10, area: "CN", from: Date.new(2010, 1, 1), to: Date.new(2012, 1, 1))
    assert_in_delta 0.0488, real, 1e-3
  end

  test "beats_inflation compares nominal to inflation" do
    args = { area: "CN", from: Date.new(2010, 1, 1), to: Date.new(2012, 1, 1) }
    assert_equal true, @cpi.beats_inflation?(nominal: 0.10, **args)
    assert_equal false, @cpi.beats_inflation?(nominal: 0.02, **args)
  end

  test "fisher is a pure helper" do
    assert_in_delta 0.047619, RealReturn::Cpi.fisher(nominal: 0.10, inflation: 0.05), 1e-6
  end

  test "returns nil when CPI data is unavailable" do
    assert_nil @cpi.annualized(area: "ZZ", from: Date.new(2010, 1, 1), to: Date.new(2012, 1, 1))
  end
end
