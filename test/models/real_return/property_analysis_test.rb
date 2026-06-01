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
end
