require "test_helper"

class RealReturn::ModelPortfolioTest < ActiveSupport::TestCase
  def cma
    RealReturn::Cma.new(path: Rails.root.join("test", "fixtures", "files", "real_return", "cma.sample.yml"))
  end

  test "bucket_class maps buckets to region-aware CMA classes" do
    assert_equal "equity_cn", RealReturn::ModelPortfolio.bucket_class(:equity, "CNY")
    assert_equal "equity_us", RealReturn::ModelPortfolio.bucket_class(:equity, "USD")
    assert_equal "govbond", RealReturn::ModelPortfolio.bucket_class(:bonds, "CNY")
    assert_equal "real_estate_cn", RealReturn::ModelPortfolio.bucket_class(:real_estate, "CNY")
    assert_equal "deposit", RealReturn::ModelPortfolio.bucket_class(:cash, "CNY")
  end

  test "assets_for splits total by normalized weights into CMA classes" do
    assets = RealReturn::ModelPortfolio.assets_for({ equity: 0.6, bonds: 0.4 }, total: 1000.0, currency: "CNY", cma: cma, horizon: 20)
    by_class = assets.to_h { |a| [ a[:asset_class], a ] }
    assert_in_delta 600.0, by_class["equity_cn"][:value], 1e-6
    assert_in_delta 400.0, by_class["govbond"][:value], 1e-6
    assert_in_delta 0.045, by_class["equity_cn"][:expected_real_return], 1e-9
  end

  test "weights need not sum to 1 (normalized)" do
    assets = RealReturn::ModelPortfolio.assets_for({ equity: 30, bonds: 10 }, total: 1000.0, currency: "CNY", cma: cma, horizon: 20)
    assert_in_delta 1000.0, assets.sum { |a| a[:value] }, 1e-6
  end

  test "expected_real_return is the weighted average" do
    er = RealReturn::ModelPortfolio.expected_real_return({ equity: 0.6, bonds: 0.4 }, currency: "CNY", cma: cma, horizon: 20)
    assert_in_delta (0.6 * 0.045 + 0.4 * 0.004), er, 1e-9
  end

  test "all-cash maps to deposit" do
    assert_in_delta(-0.003, RealReturn::ModelPortfolio.expected_real_return({ cash: 1.0 }, currency: "CNY", cma: cma, horizon: 20), 1e-9)
  end

  test "PRESETS lists the model portfolios" do
    assert_equal [ "All equity", "60/40", "Diversified", "All cash" ], RealReturn::ModelPortfolio::PRESETS.keys
  end

  test "assets_for carries horizon-aware mean and regime fields" do
    cma = RealReturn::Cma.new(path: Rails.root.join("test", "fixtures", "files", "real_return", "cma.sample.yml"))
    a = RealReturn::ModelPortfolio.assets_for({ equity: 1.0 }, total: 1_000.0, currency: "CNY", cma: cma, horizon: 20).first
    assert a.key?(:mean_start)
    assert a.key?(:mean_end)
    assert a.key?(:regime_offsets)
  end
end
