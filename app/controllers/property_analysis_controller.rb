class PropertyAnalysisController < ApplicationController
  def show
    @currency = Current.family.currency
    @region = params[:region].to_s.downcase == "us" ? "us" : "cn"
    klass = "real_estate_#{@region}"
    cma = RealReturn::Cma.new
    c = cma.components(klass) || {}
    val = c["valuation"].is_a?(Hash) ? c["valuation"] : { "current" => 1.0, "target" => 1.0 }

    @holding_years = clamp(params[:holding_years].to_i, 5, 40, 30)
    @price = positive_or(params[:price], 1_000_000.0)
    default_rent = (@price * c.fetch("net_rental_yield", 0.03).to_f / 12.0).round
    @monthly_rent = positive_or(params[:monthly_rent], default_rent)
    @inputs = {
      ltv: pct_or(params[:ltv], 0.60), mortgage_rate: pct_or(params[:mortgage_rate], 0.05),
      amortization_years: clamp(params[:amortization_years].to_i, 5, 40, 30),
      opex_pct: pct_or(params[:opex_pct], 0.25), vacancy_pct: pct_or(params[:vacancy_pct], 0.05),
      inflation: pct_or(params[:inflation], @region == "us" ? 0.025 : 0.02)
    }

    @analysis = RealReturn::PropertyAnalysis.new(
      price: @price, monthly_rent: @monthly_rent, holding_years: @holding_years,
      ltv: @inputs[:ltv], mortgage_rate: @inputs[:mortgage_rate], amortization_years: @inputs[:amortization_years],
      opex_pct: @inputs[:opex_pct], vacancy_pct: @inputs[:vacancy_pct],
      real_rent_growth: c.fetch("real_rent_growth", 0.0).to_f,
      real_rent_growth_end: c.dig("glide", "real_rent_growth"),
      price_to_rent_current: val.fetch("current", 1.0).to_f, price_to_rent_target: val.fetch("target", 1.0).to_f,
      inflation: @inputs[:inflation], sigma: cma.sigma(klass) || 0.09,
      regimes: cma.regimes, regime_offsets: c.fetch("regime_offsets", {})
    )
    @cash_flow = @analysis.cash_flow
    @distribution = @analysis.distribution

    @benchmarks = %W[govbond equity_#{@region} gold deposit].map do |k|
      { key: k, expected_real_return: cma.expected_real_return(k, horizon: @holding_years), sigma: cma.sigma(k) }
    end

    @breadcrumbs = [ [ "Home", root_path ], [ "Property analysis", nil ] ]
  end

  private
    def clamp(value, min, max, default)
      v = value.to_i
      (min..max).cover?(v) ? v : default
    end

    def positive_or(raw, default)
      v = raw.to_f
      v.positive? ? v : default
    end

    def pct_or(raw, default)
      return default if raw.blank?

      v = raw.to_f / 100.0
      v >= 0 ? v : default
    end
end
