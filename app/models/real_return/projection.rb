module RealReturn
  # Projects a family's in-scope asset basket forward via Monte Carlo (real terms).
  class Projection
    def initialize(family, as_of: Date.current, cma: Cma.new, reference_data: ReferenceData.default,
                   correlation: Correlation.new, paths: 5000, seed: 123_456)
      @family = family
      @as_of = as_of
      @base_currency = family.currency
      @cma = cma
      @reference_data = reference_data
      @correlation = correlation
      @paths = paths
      @seed = seed
    end

    # Array of { value:, asset_class:, expected_real_return:, sigma: } for in-scope accounts with data.
    def assets
      @assets ||= @family.accounts.visible.where(accountable_type: Analysis::IN_SCOPE).filter_map do |account|
        analysis = Analysis.new(account, as_of: @as_of, base_currency: @base_currency, reference_data: @reference_data)
        value = analysis.current_value
        next nil if value.nil? || value <= 0

        klass = AssetClass.for(account, currency: @base_currency)
        er = @cma.expected_real_return(klass)
        sigma = @cma.sigma(klass)
        next nil if er.nil? || sigma.nil?

        { value: value, asset_class: klass, expected_real_return: er, sigma: sigma }
      end
    end

    # => { years:, p15:, p50:, p85: } of real basket value over [0, horizon].
    def project(horizon:, annual_contribution: 0.0, contribution_growth: 0.0)
      list = assets
      return empty_result(horizon) if list.empty?

      MonteCarlo.new(
        assets: list, correlation: @correlation, horizon: horizon,
        annual_contribution: annual_contribution, contribution_growth: contribution_growth,
        paths: @paths, seed: @seed
      ).run
    end

    private
      def empty_result(horizon)
        zeros = Array.new(horizon + 1, 0.0)
        { years: (0..horizon).to_a, p15: zeros, p50: zeros.dup, p85: zeros.dup }
      end
  end
end
