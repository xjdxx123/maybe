module RealReturn
  # Projects the current basket + alternative model portfolios (same capital, savings,
  # horizon, correlation, seed — only the allocation differs) into comparable rows.
  class PortfolioComparison
    def initialize(family, as_of: Date.current, horizon: 30, annual_contribution: 0.0, custom_weights: nil,
                   cma: Cma.new, reference_data: ReferenceData.default, correlation: Correlation.new,
                   paths: 5000, seed: 123_456)
      @family = family
      @as_of = as_of
      @horizon = horizon
      @annual_contribution = annual_contribution
      @custom_weights = custom_weights
      @cma = cma
      @reference_data = reference_data
      @correlation = correlation
      @paths = paths
      @seed = seed
      @currency = family.currency
    end

    # Ordered rows: Current (actual basket) first, then presets, then Custom (if given).
    # Each: { name:, weights: (nil for Current), expected_real_return:, median: [..], terminal: {p15:,p50:,p85:} }
    def rows
      projection = Projection.new(@family, as_of: @as_of, cma: @cma, reference_data: @reference_data,
                                  correlation: @correlation, paths: @paths, seed: @seed)
      current = projection.project(horizon: @horizon, annual_contribution: @annual_contribution)
      start_value = current[:p50].first

      out = [ build_row("Current", nil, current, current_expected_return(projection.assets, start_value)) ]
      return out if start_value <= 0

      ModelPortfolio::PRESETS.each { |name, weights| out << alternative_row(name, weights, start_value) }
      if @custom_weights && @custom_weights.values.sum { |w| w.to_f } > 0
        out << alternative_row("Custom", @custom_weights, start_value)
      end
      out
    end

    private
      def alternative_row(name, weights, total)
        assets = ModelPortfolio.assets_for(weights, total: total, currency: @currency, cma: @cma)
        result = MonteCarlo.new(assets: assets, correlation: @correlation, horizon: @horizon,
                                annual_contribution: @annual_contribution, paths: @paths, seed: @seed).run
        build_row(name, weights, result, ModelPortfolio.expected_real_return(weights, currency: @currency, cma: @cma))
      end

      def build_row(name, weights, result, expected_real_return)
        {
          name: name, weights: weights, expected_real_return: expected_real_return,
          median: result[:p50],
          terminal: { p15: result[:p15].last, p50: result[:p50].last, p85: result[:p85].last }
        }
      end

      def current_expected_return(assets, total)
        return nil if total <= 0 || assets.empty?

        assets.sum(0.0) { |a| a[:expected_real_return] * (a[:value] / total) }
      end
  end
end
