module RealReturn
  # Per-account real-return analysis. Reads Maybe's ledger, normalizes to the base
  # currency, and answers nominal / real / benchmark questions via the Phase-1 POROs.
  class Analysis
    MARKET_PRICED = %w[Investment Crypto].freeze
    MANUAL_VALUED = %w[Property Vehicle OtherAsset].freeze
    IN_SCOPE = (MARKET_PRICED + MANUAL_VALUED).freeze

    attr_reader :account, :as_of, :base_currency

    def initialize(account, as_of: Date.current, base_currency: nil, reference_data: ReferenceData.default)
      @account = account
      @as_of = as_of
      @base_currency = base_currency || account.family.currency
      @reference_data = reference_data
      @cpi = Cpi.new(reference_data: reference_data)
      @benchmark = Benchmark.new(reference_data: reference_data)
    end

    def in_scope?
      IN_SCOPE.include?(account.accountable_type)
    end

    # Signed cashflows in base currency: [Date, Float]. Outflows negative, terminal positive.
    def flows
      @flows ||= build_flows.compact
    end

    # Contributions as positive [Date, Float] (money invested), for counterfactuals.
    def contributions
      flows.select { |(_, amt)| amt.negative? }.map { |(d, amt)| [ d, -amt ] }
    end

    def start_date
      contributions.map(&:first).min
    end

    def estimated?
      flows # ensure terminal computed (sets @estimated as a side effect)
      @estimated == true
    end

    def has_data?
      contributions.any? && (terminal_value&.positive? || false)
    end

    def nominal_return
      Xirr.compute(flows)
    end

    def real_return
      r = nominal_return
      return nil if r.nil? || start_date.nil?

      @cpi.real_return(nominal: r, area: cpi_area, from: start_date, to: as_of)
    end

    def beats_inflation?
      r = nominal_return
      return nil if r.nil? || start_date.nil?

      @cpi.beats_inflation?(nominal: r, area: cpi_area, from: start_date, to: as_of)
    end

    # { "sp500" => rate_or_nil, ... } counterfactual money-weighted returns.
    def benchmark_returns
      Region::BENCHMARK_KEYS.index_with do |key|
        @benchmark.counterfactual_return(
          contributions: contributions, key: key, as_of: as_of,
          region: Region.for_benchmark(key, base_currency)
        )
      end
    end

    def cpi_area
      Region.cpi_area(base_currency)
    end

    private
      def build_flows
        if MARKET_PRICED.include?(account.accountable_type)
          market_priced_flows
        else
          manual_valued_flows
        end
      end

      # Each trade is a signed cashflow (entry.amount = qty*price: buy +, sell -),
      # negated to the Xirr convention. Terminal = current holdings value.
      def market_priced_flows
        flows = account.entries.where(entryable_type: "Trade").map do |entry|
          amt = to_base(entry.amount, entry.currency, entry.date)
          amt && [ entry.date, -amt ]
        end
        tv = terminal_value
        flows << [ as_of, tv ] if tv&.positive?
        flows
      end

      # Opening valuation = purchase; terminal = latest valuation, else house-index estimate.
      def manual_valued_flows
        opening = valuations.first
        return [] if opening.nil? || opening.date >= as_of # need a positive holding period

        purchase = to_base(opening.amount, opening.currency, opening.date)
        tv = terminal_value
        return [] if purchase.nil? || purchase <= 0 || tv.nil? || tv <= 0

        [ [ opening.date, -purchase ], [ as_of, tv ] ]
      end

      def valuations
        @valuations ||= account.entries.where(entryable_type: "Valuation").order(:date).to_a
      end

      def terminal_value
        return @terminal_value if defined?(@terminal_value)

        @terminal_value = if MARKET_PRICED.include?(account.accountable_type)
          holdings_value
        else
          manual_terminal_value
        end
      end

      def holdings_value
        latest_date = account.holdings.maximum(:date)
        return nil if latest_date.nil?

        account.holdings.where(date: latest_date).sum(0.0) do |h|
          to_base(h.amount, h.currency, as_of) || 0.0
        end
      end

      def manual_terminal_value
        return nil if valuations.empty?

        if valuations.length >= 2
          latest = valuations.last
          to_base(latest.amount, latest.currency, latest.date)
        else
          estimate_from_index(valuations.first)
        end
      end

      # Estimate current value by scaling the purchase by the real-estate index (Property only).
      def estimate_from_index(opening)
        return nil unless account.accountable_type == "Property"

        purchase = to_base(opening.amount, opening.currency, opening.date)
        return nil if purchase.nil?

        g = @benchmark.growth(key: "real_estate", from: opening.date, to: as_of,
                              region: Region.real_estate(base_currency))
        return nil if g.nil?

        @estimated = true
        purchase * g
      end

      # Convert a Numeric amount in `currency` to a base-currency Float, or nil if no FX rate.
      def to_base(amount, currency, date)
        Money.new(amount, currency).exchange_to(base_currency, date: date).amount.to_f
      rescue Money::ConversionError
        nil
      end
  end
end
