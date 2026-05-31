module RealReturn
  # Opportunity-cost comparison: what the same money, contributed on the same dates,
  # would be worth in a benchmark vehicle. Faithful port of the validated Python engine.
  class Benchmark
    def initialize(reference_data: ReferenceData.default)
      @reference_data = reference_data
    end

    # Multiple that 1 unit invested at `from` becomes by `to`. nil if unavailable.
    def growth(key:, from:, to:, region: nil)
      v0 = @reference_data.benchmark_level(key: key, on: from, region: region)
      v1 = @reference_data.benchmark_level(key: key, on: to, region: region)
      return nil if v0.nil? || v1.nil? || v0 <= 0

      v1 / v0
    end

    # Terminal value of investing each contribution (positive amount, at its date)
    # into `key` and holding to `as_of`. nil if any growth factor is unavailable.
    def counterfactual_terminal(contributions:, key:, as_of:, region: nil)
      terminal = 0.0
      contributions.each do |(date, amount)|
        g = growth(key: key, from: date, to: as_of, region: region)
        return nil if g.nil?

        terminal += amount * g
      end
      terminal
    end

    # Money-weighted return (XIRR) of the counterfactual. nil if unavailable.
    def counterfactual_return(contributions:, key:, as_of:, region: nil)
      return nil if contributions.empty?

      terminal = counterfactual_terminal(contributions: contributions, key: key, as_of: as_of, region: region)
      return nil if terminal.nil?

      flows = contributions.map { |(date, amount)| [ date, -amount ] }
      flows << [ as_of, terminal ]
      RealReturn::Xirr.compute(flows)
    end

    # Annualized return of `key` over [from, to] (Actual/365). nil if unavailable.
    def annualized(key:, from:, to:, region: nil)
      g = growth(key: key, from: from, to: to, region: region)
      days = (to - from).to_i
      return nil if g.nil? || g <= 0 || days <= 0

      g**(365.0 / days) - 1.0
    end

    # Rank [label, value] rows high -> low; nil values last.
    def self.rank(rows)
      rows.sort_by { |(_, value)| [ value.nil? ? 1 : 0, -(value || 0.0) ] }
    end
  end
end
