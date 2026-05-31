module RealReturn
  # Projects the current basket + alternative model portfolios into comparable rows.
  # Every portfolio shares the same starting capital, annual savings, horizon, correlation
  # and RNG seed, so only the allocation differs and runs are reproducible. Each portfolio
  # is simulated independently (its own draws from the seeded RNG) — these are distribution
  # bands to compare, not a single shared market scenario replayed across allocations.
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
      current = projection.project(horizon: @horizon, annual_contribution: @annual_contribution)
      start_value = current[:p50].first

      out = [ build_row("Current", nil, current, current_expected_return(projection.assets(horizon: @horizon), start_value)) ]
      return out if start_value <= 0

      ModelPortfolio::PRESETS.each { |name, weights| out << alternative_row(name, weights, start_value) }
      out << alternative_row("Custom", @custom_weights, start_value) if custom_weights_present?
      out
    end

    # Ordered, de-duped CMA classes referenced by ANY row (Current's holdings + presets + custom),
    # so every expected-return number shown on the page has a traceable formula.
    # No additional Monte Carlo — reuses the memoized projection.
    def referenced_asset_classes
      held = projection.assets(horizon: @horizon).map { |a| a[:asset_class] }
      preset = ModelPortfolio::PRESETS.values.flat_map { |w| ModelPortfolio.resolved(w, @currency, @cma, @horizon).map { |x| x[:klass] } }
      custom = custom_weights_present? ? ModelPortfolio.resolved(@custom_weights, @currency, @cma, @horizon).map { |x| x[:klass] } : []
      (held + preset + custom).uniq
    end

    private
      def custom_weights_present?
        @custom_weights && @custom_weights.values.sum { |w| w.to_f } > 0
      end

      def projection
        @projection ||= Projection.new(@family, as_of: @as_of, cma: @cma, reference_data: @reference_data,
                                       correlation: @correlation, paths: @paths, seed: @seed)
      end

      def alternative_row(name, weights, total)
        assets = ModelPortfolio.assets_for(weights, total: total, currency: @currency, cma: @cma, horizon: @horizon)
        result = MonteCarlo.new(assets: assets, correlation: @correlation, horizon: @horizon,
                                annual_contribution: @annual_contribution, paths: @paths, seed: @seed,
                                regimes: @cma.regimes).run
        build_row(name, weights, result, ModelPortfolio.expected_real_return(weights, currency: @currency, cma: @cma, horizon: @horizon))
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
