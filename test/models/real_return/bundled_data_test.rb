require "test_helper"

class RealReturn::BundledDataTest < ActiveSupport::TestCase
  setup { @data = RealReturn::ReferenceData::Bundled.new } # default config/real_return paths

  test "cpi series load and are positive and rising for CN and US" do
    %w[CN US].each do |area|
      range = @data.cpi_range(area: area)
      assert range, "missing CPI range for #{area}"
      v_start = @data.cpi_index(area: area, on: range.begin)
      v_end = @data.cpi_index(area: area, on: range.end)
      assert v_start.positive? && v_end.positive?, "#{area} CPI must be positive"
      assert v_end >= v_start, "#{area} CPI should rise over the full range"
    end
  end

  test "each non-real-estate benchmark loads with a positive level at its latest year" do
    %w[sp500 csi300 gold deposit govbond].each do |key|
      range = @data.benchmark_range(key: key)
      assert range, "missing benchmark range for #{key}"
      assert @data.benchmark_level(key: key, on: range.end).positive?, "#{key} latest level must be positive"
    end
  end

  test "real_estate is region-keyed and positive for CN and US" do
    assert @data.benchmark_level(key: "real_estate", on: Date.new(2015, 1, 1), region: "US")&.positive?
    assert @data.benchmark_level(key: "real_estate", on: Date.new(2015, 1, 1), region: "CN")&.positive?
  end
end
