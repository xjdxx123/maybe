require "test_helper"

class RealReturn::ReferenceData::BundledTest < ActiveSupport::TestCase
  setup do
    dir = Rails.root.join("test", "fixtures", "files", "real_return")
    @data = RealReturn::ReferenceData::Bundled.new(
      cpi_path: dir.join("cpi.sample.yml"),
      benchmarks_path: dir.join("benchmarks.sample.yml")
    )
  end

  test "cpi_index returns the exact value on a year boundary" do
    assert_in_delta 105.0, @data.cpi_index(area: "CN", on: Date.new(2011, 1, 1)), 1e-9
  end

  test "cpi_index interpolates by day-fraction within a year" do
    # 2011-07-02 is day 182 of a 365-day year -> fraction ~0.4986 between 105 and 110
    value = @data.cpi_index(area: "CN", on: Date.new(2011, 7, 2))
    assert value > 107.0 && value < 108.0, "expected ~107.5, got #{value}"
  end

  test "cpi_index clamps to the latest year and is nil before the earliest" do
    assert_in_delta 110.0, @data.cpi_index(area: "CN", on: Date.new(2012, 6, 1)), 1e-9
    assert_nil @data.cpi_index(area: "CN", on: Date.new(2009, 1, 1))
  end

  test "benchmark_level reads a flat series and a region-keyed series" do
    assert_in_delta 1.20, @data.benchmark_level(key: "sp500", on: Date.new(2011, 1, 1)), 1e-9
    assert_in_delta 1.10, @data.benchmark_level(key: "real_estate", on: Date.new(2011, 1, 1), region: "CN"), 1e-9
  end

  test "ranges report the covered years" do
    assert_equal (Date.new(2010, 1, 1)..Date.new(2012, 1, 1)), @data.cpi_range(area: "CN")
    assert_nil @data.cpi_range(area: "ZZ")
  end
end
