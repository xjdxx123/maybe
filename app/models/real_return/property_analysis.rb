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

    # Levered real equity over the holding period: percentile bands per year (p10..p90) + terminal
    # stats, annualized levered real return percentiles, ruin probability, and a 5/10/20/30y table.
    def distribution
      n = @holding_years
      regimes = @regimes.to_a
      rng = Random.new(@seed)
      loan = @price * @ltv
      down = @price - loan
      ds_nominal = debt_service(loan)
      noi0 = cash_flow[:noi]
      val_amort = valuation_amort(n)

      by_year = Array.new(n + 1) { [] }
      @paths.times do
        regime = pick_regime(rng, regimes)
        off = regime ? (@regime_offsets[regime] || 0.0).to_f : 0.0
        value = @price
        noi = noi0
        cum_cash = 0.0
        by_year[0] << down
        (1..n).each do |t|
          g = lerp(@real_rent_growth, @real_rent_growth_end, t.to_f / n)
          mean_a = g + val_amort + off
          mean_a = -0.99 if mean_a < -0.99
          drift = Math.log(1.0 + mean_a) - 0.5 * @sigma**2
          value *= Math.exp(drift + @sigma * gaussian(rng))
          # v1 simplification: NOI is deterministic (rent glide only — no regime/σ); price carries the risk.
          noi *= (1.0 + g)
          deflator = (1.0 + @inflation)**t
          # cum_cash: undiscounted sum of real net cash flows (no time-value weighting) — v1.
          cum_cash += noi - ds_nominal / deflator
          by_year[t] << value - nominal_balance(loan, t, ds_nominal) / deflator + cum_cash
        end
      end

      terminal = by_year[n]
      # Annualized equity CAGR = (terminal equity / down payment)^(1/n) − 1. NOT an IRR — intermediate
      # cash flows are collapsed into terminal equity. nil when the equity percentile is ≤ 0 (underwater).
      ann = ->(equity) { (down <= 0 || equity <= 0) ? nil : (equity / down)**(1.0 / n) - 1.0 }
      {
        years: (0..n).to_a,
        p10: by_year.map { |v| percentile(v, 10) },
        p25: by_year.map { |v| percentile(v, 25) },
        p50: by_year.map { |v| percentile(v, 50) },
        p75: by_year.map { |v| percentile(v, 75) },
        p90: by_year.map { |v| percentile(v, 90) },
        terminal: { p10: percentile(terminal, 10), p50: percentile(terminal, 50), p90: percentile(terminal, 90) },
        annualized: { p10: ann.call(percentile(terminal, 10)), p50: ann.call(percentile(terminal, 50)),
                      p90: ann.call(percentile(terminal, 90)) },
        negative_equity_share: terminal.count { |e| e <= 0 }.to_f / @paths,
        table: [ 5, 10, 20, 30 ].select { |y| y <= n }.map do |y|
          { years: y, p10: percentile(by_year[y], 10), p50: percentile(by_year[y], 50), p90: percentile(by_year[y], 90) }
        end
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

      def valuation_amort(n)
        return 0.0 unless @price_to_rent_current.positive? && @price_to_rent_target.positive?

        (@price_to_rent_target / @price_to_rent_current)**(1.0 / n) - 1.0
      end

      def lerp(a, b, frac)
        a + (b - a) * frac
      end

      # Remaining nominal loan balance after t annual payments (clamped >= 0). `pay` is the
      # precomputed annual debt service (passed from the loop to avoid recomputing it each year).
      def nominal_balance(loan, t, pay)
        return 0.0 if loan <= 0 || @amortization_years <= 0

        bal =
          if @mortgage_rate <= 0
            loan - pay * t
          else
            r = @mortgage_rate
            loan * (1.0 + r)**t - pay * ((1.0 + r)**t - 1.0) / r
          end
        [ bal, 0.0 ].max
      end

      # NOTE: gaussian / pick_regime / percentile are intentionally duplicated from MonteCarlo to keep
      # this PORO self-contained. If a third simulator appears, extract a shared RealReturn sampling module.
      def gaussian(rng)
        u1 = rng.rand
        u1 = 1e-12 if u1 <= 0.0
        Math.sqrt(-2.0 * Math.log(u1)) * Math.cos(2.0 * Math::PI * rng.rand)
      end

      def pick_regime(rng, regimes)
        return nil if regimes.empty?

        u = rng.rand
        cum = 0.0
        regimes.each { |name, p| cum += p.to_f; return name if u < cum }
        regimes.last[0]
      end

      def percentile(values, pct)
        sorted = values.sort
        sorted[((pct / 100.0) * (sorted.size - 1)).round]
      end
  end
end
