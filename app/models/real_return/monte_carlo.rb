module RealReturn
  # Monte-Carlo projection of a basket's REAL value. Each asset's annual real return
  # is correlated-lognormal: log(1+r_i) ~ N(m_i, sigma_i), with m_i set so E[1+r_i] = 1+mu_i,
  # and correlation applied via the Cholesky factor of the correlation matrix.
  # Annual contributions are added each year, split across assets by current weight.
  class MonteCarlo
    # assets: Array of { value:, expected_real_return:, sigma: } (old-style)
    #      or { value:, mean_start:, mean_end:, sigma:, regime_offsets: } (new-style)
    def initialize(assets:, correlation:, horizon:, annual_contribution: 0.0, contribution_growth: 0.0, paths: 5000, seed: 123_456, regimes: {})
      @assets = assets
      @correlation = correlation
      @horizon = horizon
      @annual_contribution = annual_contribution.to_f
      @contribution_growth = contribution_growth.to_f
      @paths = paths
      @seed = seed
      @regimes = regimes
    end

    # => { years: [0..horizon], p15: [...], p50: [...], p85: [...] } of real basket value.
    def run
      n = @assets.size
      l = @correlation.cholesky(n)
      mean_start = @assets.map { |a| (a[:mean_start] || a[:expected_real_return]).to_f }
      mean_end = @assets.map { |a| (a[:mean_end] || a[:mean_start] || a[:expected_real_return]).to_f }
      vol = @assets.map { |a| a[:sigma].to_f }
      offsets = @assets.map { |a| a[:regime_offsets] || {} }
      regimes = @regimes.to_a # [[name, prob], ...]; empty => no regime draw
      rng = Random.new(@seed)

      per_year = Array.new(@horizon + 1) { [] }
      @paths.times do
        regime = pick_regime(rng, regimes) # nil when no regimes
        eps = offsets.map { |o| regime ? (o[regime] || 0.0).to_f : 0.0 }
        values = @assets.map { |a| a[:value].to_f }
        contribution = @annual_contribution
        per_year[0] << values.sum
        (1..@horizon).each do |t|
          frac = t.to_f / @horizon
          u = Array.new(n) { gaussian(rng) }
          values = Array.new(n) do |i|
            mean = mean_start[i] + (mean_end[i] - mean_start[i]) * frac + eps[i]
            mean = -0.99 if mean < -0.99
            drift = Math.log(1.0 + mean) - 0.5 * vol[i]**2
            z = (0..i).sum { |k| l[i][k] * u[k] } # correlated normal for asset i
            values[i] * Math.exp(drift + vol[i] * z)
          end
          total = values.sum
          if contribution.positive? && total.positive?
            values = Array.new(n) { |i| values[i] + contribution * (values[i] / total) }
          end
          per_year[t] << values.sum
          contribution *= (1.0 + @contribution_growth)
        end
      end

      {
        years: (0..@horizon).to_a,
        p15: per_year.map { |vals| percentile(vals, 15) },
        p50: per_year.map { |vals| percentile(vals, 50) },
        p85: per_year.map { |vals| percentile(vals, 85) }
      }
    end

    private
      # Standard normal via Box-Muller.
      def gaussian(rng)
        u1 = rng.rand
        u1 = 1e-12 if u1 <= 0.0
        u2 = rng.rand
        Math.sqrt(-2.0 * Math.log(u1)) * Math.cos(2.0 * Math::PI * u2)
      end

      # Draw one regime per path from the mixture [[name, prob], ...]. Returns nil (no draw, no
      # RNG consumed) when the mixture is empty, so regime-free runs are bit-identical to before.
      def pick_regime(rng, regimes)
        return nil if regimes.empty?

        u = rng.rand
        cum = 0.0
        regimes.each { |name, p| cum += p.to_f; return name if u < cum }
        regimes.last[0]
      end

      def percentile(values, pct)
        sorted = values.sort
        idx = ((pct / 100.0) * (sorted.size - 1)).round
        sorted[idx]
      end
  end
end
