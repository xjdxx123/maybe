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

  test "a bear-heavy regime mixture widens the band and skews the median down" do
    corr = RealReturn::Correlation.new
    base = { value: 1_000_000.0, sigma: 0.12, mean_start: 0.05, mean_end: 0.05 }
    no_regime = RealReturn::MonteCarlo.new(assets: [ base ], correlation: corr, horizon: 20, paths: 4000, seed: 7).run
    regimed = RealReturn::MonteCarlo.new(assets: [ base.merge(regime_offsets: { "bear" => -0.05, "bull" => 0.02 }) ],
      correlation: corr, horizon: 20, paths: 4000, seed: 7,
      regimes: { "base" => 0.6, "bear" => 0.25, "bull" => 0.15 }).run
    spread = ->(r) { r[:p85].last - r[:p15].last }
    assert spread.call(regimed) > spread.call(no_regime), "regime mixture should widen p15..p85"
    assert regimed[:p50].last < no_regime[:p50].last, "bear-heavy mixture should pull the median down"
  end

  test "a declining glide bends the median below a flat mean of the same start" do
    corr = RealReturn::Correlation.new
    flat = RealReturn::MonteCarlo.new(assets: [ { value: 1e6, sigma: 0.10, mean_start: 0.05, mean_end: 0.05 } ],
      correlation: corr, horizon: 30, paths: 2000, seed: 7).run
    glide = RealReturn::MonteCarlo.new(assets: [ { value: 1e6, sigma: 0.10, mean_start: 0.05, mean_end: 0.02 } ],
      correlation: corr, horizon: 30, paths: 2000, seed: 7).run
    assert glide[:p50].last < flat[:p50].last
  end

  test "old-style assets (expected_real_return, no regimes) still run" do
    corr = RealReturn::Correlation.new
    r = RealReturn::MonteCarlo.new(assets: [ { value: 1_000.0, expected_real_return: 0.03, sigma: 0.1 } ],
      correlation: corr, horizon: 5, paths: 500, seed: 7).run
    assert_equal 6, r[:p50].size
    assert r[:p15].last <= r[:p50].last
  end
end
