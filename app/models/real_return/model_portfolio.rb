module RealReturn
  # Turns a bucket-weight allocation into a MonteCarlo asset list, and computes its
  # weighted expected real return, using the CMA. Buckets map (region-aware) to CMA classes.
  module ModelPortfolio
    # name => { bucket => weight }
    PRESETS = {
      "All equity" => { equity: 1.0 },
      "60/40" => { equity: 0.6, bonds: 0.4 },
      "Diversified" => { equity: 0.4, bonds: 0.2, real_estate: 0.15, gold: 0.15, cash: 0.1 },
      "All cash" => { cash: 1.0 }
    }.freeze

    BUCKETS = %i[equity bonds real_estate gold cash].freeze

    module_function

    def bucket_class(bucket, currency)
      region = Region.real_estate(currency).downcase
      case bucket.to_sym
      when :equity then "equity_#{region}"
      when :bonds then "govbond"
      when :real_estate then "real_estate_#{region}"
      when :gold then "gold"
      when :cash then "deposit"
      end
    end

    # [{ value:, asset_class:, expected_real_return:, sigma: }], total split by normalized weights.
    def assets_for(weights, total:, currency:, cma:)
      r = resolved(weights, currency, cma)
      sum = r.sum { |x| x[:w] }
      return [] if sum <= 0

      r.map do |x|
        { value: total * (x[:w] / sum), asset_class: x[:klass], expected_real_return: x[:er], sigma: x[:sigma] }
      end
    end

    # Weighted average expected real return over resolved buckets, or nil.
    def expected_real_return(weights, currency:, cma:)
      r = resolved(weights, currency, cma)
      sum = r.sum { |x| x[:w] }
      return nil if sum <= 0

      r.sum(0.0) { |x| x[:er] * (x[:w] / sum) }
    end

    # Buckets with positive weight AND a valid CMA class.
    def resolved(weights, currency, cma)
      weights.filter_map do |bucket, weight|
        w = weight.to_f
        next nil if w <= 0

        klass = bucket_class(bucket, currency)
        er = klass && cma.expected_real_return(klass)
        sigma = klass && cma.sigma(klass)
        next nil if er.nil? || sigma.nil?

        { w: w, klass: klass, er: er, sigma: sigma }
      end
    end
  end
end
