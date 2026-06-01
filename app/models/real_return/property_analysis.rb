module RealReturn
  # Per-property deal analysis: a year-1 cash-flow pro forma + a levered, real-terms Monte Carlo of
  # equity value reusing the regime/glide/valuation engine. Standalone (not tied to an Account).
  # Rates are decimals (0.05 = 5%); ltv/opex_pct/vacancy_pct are fractions. Real terms; debt nominal.
  class PropertyAnalysis
    def initialize(price:, monthly_rent:, holding_years:, ltv:, mortgage_rate:, amortization_years:,
                   opex_pct:, vacancy_pct:, real_rent_growth:, price_to_rent_current:,
                   price_to_rent_target:, inflation:, sigma:, real_rent_growth_end: nil,
                   regimes: {}, regime_offsets: {}, paths: 5000, seed: 123_456)
      @price = price.to_f
      @monthly_rent = monthly_rent.to_f
      @holding_years = holding_years.to_i
      @ltv = ltv.to_f
      @mortgage_rate = mortgage_rate.to_f
      @amortization_years = amortization_years.to_i
      @opex_pct = opex_pct.to_f
      @vacancy_pct = vacancy_pct.to_f
      @real_rent_growth = real_rent_growth.to_f
      @real_rent_growth_end = (real_rent_growth_end || real_rent_growth).to_f
      @price_to_rent_current = price_to_rent_current.to_f
      @price_to_rent_target = price_to_rent_target.to_f
      @inflation = inflation.to_f
      @sigma = sigma.to_f
      @regimes = regimes || {}
      @regime_offsets = regime_offsets || {}
      @paths = paths
      @seed = seed
    end

    # Year-1 pro forma (real terms). Returns a Hash.
    def cash_flow
      annual_rent = @monthly_rent * 12.0
      noi = annual_rent * (1.0 - @vacancy_pct - @opex_pct)
      loan = @price * @ltv
      down = @price - loan
      ds = debt_service(loan)
      {
        annual_rent: annual_rent,
        gross_yield: @price.zero? ? 0.0 : annual_rent / @price,
        noi: noi,
        cap_rate: @price.zero? ? 0.0 : noi / @price,
        loan: loan,
        down_payment: down,
        debt_service: ds,
        cash_on_cash: down.positive? ? (noi - ds) / down : nil,
        dscr: ds.zero? ? nil : noi / ds,
        break_even_occupancy: annual_rent.zero? ? nil : @opex_pct + ds / annual_rent
      }
    end

    private
      # Annual fixed-rate amortizing payment on `loan` (nominal). 0 if no loan/term.
      def debt_service(loan)
        return 0.0 if loan <= 0 || @amortization_years <= 0
        return loan / @amortization_years if @mortgage_rate <= 0

        r = @mortgage_rate
        loan * r / (1.0 - (1.0 + r)**(-@amortization_years))
      end
  end
end
