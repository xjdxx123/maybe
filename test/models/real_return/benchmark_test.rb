require "test_helper"

class RealReturn::BenchmarkTest < ActiveSupport::TestCase
  setup do
    dir = Rails.root.join("test", "fixtures", "files", "real_return")
    data = RealReturn::ReferenceData::Bundled.new(
      cpi_path: dir.join("cpi.sample.yml"),
      benchmarks_path: dir.join("benchmarks.sample.yml")
    )
    @bench = RealReturn::Benchmark.new(reference_data: data)
  end

  test "growth is the level ratio between two dates" do
    g = @bench.growth(key: "sp500", from: Date.new(2010, 1, 1), to: Date.new(2012, 1, 1))
    assert_in_delta 1.5, g, 1e-9
  end

  test "counterfactual terminal scales each contribution by its growth" do
    contributions = [ [ Date.new(2010, 1, 1), 1000.0 ] ]
    terminal = @bench.counterfactual_terminal(contributions: contributions, key: "sp500", as_of: Date.new(2012, 1, 1))
    assert_in_delta 1500.0, terminal, 1e-6
  end

  test "counterfactual return is the money-weighted rate of the counterfactual" do
    contributions = [ [ Date.new(2010, 1, 1), 1000.0 ] ]
    # terminal 1500 over 730 days => 1.5**(365/730) - 1 ~= 0.2247
    rate = @bench.counterfactual_return(contributions: contributions, key: "sp500", as_of: Date.new(2012, 1, 1))
    assert_in_delta 0.2247, rate, 1e-3
  end

  test "returns nil when the benchmark series is missing" do
    contributions = [ [ Date.new(2010, 1, 1), 1000.0 ] ]
    assert_nil @bench.counterfactual_return(contributions: contributions, key: "missing", as_of: Date.new(2012, 1, 1))
  end

  test "rank orders rows high to low with nils last" do
    ranked = RealReturn::Benchmark.rank([ [ "a", 0.1 ], [ "b", nil ], [ "c", 0.3 ] ])
    assert_equal [ "c", "a", "b" ], ranked.map(&:first)
  end
end
