module RealReturn
  # Family-level rollup: merges all in-scope asset accounts' cashflows into one
  # schedule for portfolio money-weighted metrics, plus a benchmark league table.
  class PortfolioReport
    attr_reader :family, :as_of, :base_currency

    def initialize(family, as_of: Date.current, reference_data: ReferenceData.default)
      @family = family
      @as_of = as_of
      @base_currency = family.currency
      @reference_data = reference_data
      @cpi = Cpi.new(reference_data: reference_data)
      @benchmark = Benchmark.new(reference_data: reference_data)
    end

    def analyses
      @analyses ||= family.accounts.visible
        .where(accountable_type: Analysis::IN_SCOPE)
        .map { |account| Analysis.new(account, as_of: as_of, base_currency: base_currency, reference_data: @reference_data) }
        .select(&:has_data?)
    end

    # All accounts' signed cashflows merged (each account contributes its own terminal at as_of).
    def flows
      @flows ||= analyses.flat_map(&:flows)
    end

    def contributions
      flows.select { |(_, amt)| amt.negative? }.map { |(d, amt)| [ d, -amt ] }
    end

    def start_date
      contributions.map(&:first).min
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

    # Ranked [label, annualized_or_nil]: your portfolio + each benchmark + a CPI row.
    def league_table
      rows = [ [ "You", nominal_return ] ]
      Region::BENCHMARK_KEYS.each do |key|
        rows << [ key, @benchmark.counterfactual_return(
          contributions: contributions, key: key, as_of: as_of,
          region: Region.for_benchmark(key, base_currency)
        ) ]
      end
      rows << [ "cpi", cpi_annualized ]
      Benchmark.rank(rows)
    end

    def cpi_area
      Region.cpi_area(base_currency)
    end

    private
      def cpi_annualized
        return nil if start_date.nil?

        @cpi.annualized(area: cpi_area, from: start_date, to: as_of)
      end
  end
end
