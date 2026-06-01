require "test_helper"

class RealReturn::PropertyAnalysisTest < ActiveSupport::TestCase
  def build(**overrides)
    defaults = {
      price: 1_000_000.0, monthly_rent: 3_000.0, holding_years: 30, ltv: 0.6,
      mortgage_rate: 0.05, amortization_years: 30, opex_pct: 0.25, vacancy_pct: 0.05,
      real_rent_growth: 0.0, price_to_rent_current: 1.0, price_to_rent_target: 1.0,
      inflation: 0.02, sigma: 0.09, regimes: {}, regime_offsets: {}, paths: 800, seed: 9
    }
    RealReturn::PropertyAnalysis.new(**defaults.merge(overrides))
  end

  test "cash_flow computes the year-1 pro forma" do
    cf = build.cash_flow
    assert_in_delta 36_000.0, cf[:annual_rent], 1e-6
    assert_in_delta 0.036, cf[:gross_yield], 1e-9
    assert_in_delta 25_200.0, cf[:noi], 1e-6
    assert_in_delta 0.0252, cf[:cap_rate], 1e-9
    assert_in_delta 400_000.0, cf[:down_payment], 1e-6
    assert_in_delta 39_031.6, cf[:debt_service], 1.0
    assert_in_delta cf[:noi] / cf[:debt_service], cf[:dscr], 1e-9
    assert_in_delta (cf[:noi] - cf[:debt_service]) / cf[:down_payment], cf[:cash_on_cash], 1e-9
    assert_in_delta 0.25 + cf[:debt_service] / cf[:annual_rent], cf[:break_even_occupancy], 1e-9
  end

  test "cash_flow with no leverage: zero debt service, nil dscr, cash-on-cash == cap rate" do
    cf = build(ltv: 0.0).cash_flow
    assert_equal 0.0, cf[:debt_service]
    assert_nil cf[:dscr]
    assert_in_delta cf[:cap_rate], cf[:cash_on_cash], 1e-9
  end

  test "distribution percentiles are ordered and reproducible" do
    d = build(paths: 1500).distribution
    t = d[:terminal]
    assert_operator t[:p10], :<=, t[:p50]
    assert_operator t[:p50], :<=, t[:p90]
    assert_equal d[:years].size, d[:p50].size
    assert_in_delta d[:p50].last, build(paths: 1500).distribution[:p50].last, 1e-6
  end

  test "higher leverage widens the band and raises the ruin probability" do
    low = build(ltv: 0.2, paths: 2000).distribution
    high = build(ltv: 0.8, paths: 2000).distribution
    # Leverage amplifies return dispersion: annualized p90-p10 spread widens with LTV
    ann_spread = ->(d) { d[:annualized][:p90] - d[:annualized][:p10] }
    assert_operator ann_spread.call(high), :>, ann_spread.call(low)
    assert_operator high[:negative_equity_share], :>=, low[:negative_equity_share]
  end

  test "a valuation de-rating lowers the median terminal equity" do
    flat = build(price_to_rent_current: 1.0, price_to_rent_target: 1.0, ltv: 0.0, paths: 2000).distribution
    derate = build(price_to_rent_current: 1.3, price_to_rent_target: 1.0, ltv: 0.0, paths: 2000).distribution
    assert_operator derate[:terminal][:p50], :<, flat[:terminal][:p50]
  end

  test "distribution exposes a multi-horizon table for years <= holding period" do
    d = build(holding_years: 10).distribution
    assert_equal [ 5, 10 ], d[:table].map { |row| row[:years] }
  end
end
