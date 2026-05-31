module RealReturn
  # Capital Market Assumptions: expected REAL return (neutral) and volatility per
  # asset class, from documented, editable building-block inputs (config/real_return/cma.yml).
  class Cma
    DEFAULT_PATH = Rails.root.join("config", "real_return", "cma.yml")

    # Horizon over which a valuation gap fully reverts when none is given.
    DEFAULT_HORIZON = 30

    # Display label + provenance type per building-block input. `type` is methodological
    # (independent of the stored numbers): :observable = anchored to market/index data,
    # :assumption = forward judgment. Nuance lives in the per-input source text.
    COMPONENTS = {
      "dividend_yield"       => { label: "Dividend yield",          type: :observable },
      "net_dilution"         => { label: "Net dilution / buybacks", type: :observable },
      "real_earnings_growth" => { label: "Real earnings growth",    type: :assumption },
      "valuation_reversion"  => { label: "Valuation reversion",     type: :assumption },
      "net_rental_yield"     => { label: "Net rental yield",        type: :observable },
      "real_rent_growth"     => { label: "Real rent growth",        type: :assumption },
      "real_yield"           => { label: "Real yield",              type: :observable },
      "real_rate"            => { label: "Real rate",               type: :observable },
      "real_return"          => { label: "Real return",             type: :assumption }
    }.freeze

    def initialize(path: DEFAULT_PATH)
      @path = path
    end

    # Base-regime expected real return over `horizon` (start/end average of the gliding mean).
    # nil if unknown. horizon: nil + fixed-reversion class == the old constant.
    def expected_real_return(asset_class, horizon: nil)
      bounds = contribution_bounds(asset_class, horizon)
      return nil if bounds.nil?

      (sum(bounds[0]) + sum(bounds[1])) / 2.0
    end

    # Inputs the Monte Carlo needs for one asset over `horizon`:
    # { mean_start:, mean_end:, regime_offsets: {name=>offset}, sigma: }, or nil if unknown.
    def projection_inputs(asset_class, horizon:)
      bounds = contribution_bounds(asset_class, horizon)
      return nil if bounds.nil?

      a = data[asset_class.to_s]
      {
        mean_start: sum(bounds[0]),
        mean_end: sum(bounds[1]),
        regime_offsets: (a["regime_offsets"] || {}).transform_values(&:to_f),
        sigma: a["sigma"].to_f
      }
    end

    # Global regime mixture { name => probability }, or {} if absent.
    def regimes
      data["regimes"] || {}
    end

    # Ordered, decorated building blocks whose contributions are the start/end average and sum to
    # expected_real_return(horizon:): [{ key:, label:, type:, contribution:, source:, note: }].
    # `note` annotates the glide ("4.0% → 2.0%") or valuation ("30→20 over 30y"). Empty if unknown.
    def breakdown(asset_class, horizon: nil)
      bounds = contribution_bounds(asset_class, horizon)
      return [] if bounds.nil?

      cs_start, cs_end = bounds
      a = data[asset_class.to_s]
      cs_start.each_with_index.map do |(key, start_value), i|
        meta = COMPONENTS[key] || { label: key, type: :assumption }
        { key: key, label: meta[:label], type: meta[:type],
          contribution: (start_value + cs_end[i][1]) / 2.0,
          source: a.dig("sources", key), note: component_note(a, key, horizon) }
      end
    end

    def sigma(asset_class)
      a = data[asset_class.to_s]
      a && a["sigma"]&.to_f
    end

    def components(asset_class)
      data[asset_class.to_s]
    end

    def metadata
      data["metadata"] || {}
    end

    def asset_classes
      data.keys - %w[metadata regimes]
    end

    private
      def sum(contributions)
        contributions.sum(0.0) { |_key, value| value }
      end

      # [start_contributions, end_contributions] for the gliding mean, or nil if class unknown.
      # The single start/end pair that expected_real_return / projection_inputs / breakdown share,
      # so their numbers stay consistent regardless of the glide shape.
      def contribution_bounds(asset_class, horizon)
        cs_start = contributions(asset_class, horizon: horizon, at: :start)
        return nil if cs_start.nil?

        [ cs_start, contributions(asset_class, horizon: horizon, at: :end) ]
      end

      # Formula as data: ordered [component_key, signed_contribution] for `asset_class` over
      # `horizon`. `at` selects the gliding component's value (:start or :end). nil if unknown.
      def contributions(asset_class, horizon:, at:)
        a = data[asset_class.to_s]
        return nil if a.nil?

        years = horizon || DEFAULT_HORIZON
        case a["kind"]
        when "equity"
          [ [ "dividend_yield", a["dividend_yield"].to_f ],
            [ "net_dilution", -a["net_dilution"].to_f ],
            [ "real_earnings_growth", glide_value(a, "real_earnings_growth", at) ],
            [ "valuation_reversion", valuation_amort(a, years) ] ]
        when "real_estate"
          [ [ "net_rental_yield", a["net_rental_yield"].to_f ],
            [ "real_rent_growth", glide_value(a, "real_rent_growth", at) ],
            [ "valuation_reversion", valuation_amort(a, years) ] ]
        when "bond" then [ [ "real_yield", a["real_yield"].to_f ] ]
        when "cash" then [ [ "real_rate", a["real_rate"].to_f ] ]
        else             [ [ "real_return", a["real_return"].to_f ] ]
        end
      end

      # A gliding component at `at` (:start = today's base, :end = glide terminal). No glide -> base.
      def glide_value(a, key, at)
        base = a[key].to_f
        terminal = a.dig("glide", key)
        return base if terminal.nil?

        case at
        when :start then base
        when :end   then terminal.to_f
        else raise ArgumentError, "at must be :start or :end, got #{at.inspect}"
        end
      end

      # Valuation contribution, constant across years for a given horizon. valuation:{current,target}
      # are valuation LEVELS (e.g. CAPE 33->20, or price/rent 1.35->1.0): reverts via
      # (target/current)^(1/N)-1. Else the fixed valuation_reversion; else 0.
      def valuation_amort(a, years)
        v = a["valuation"]
        if v.is_a?(Hash) && v["current"].to_f.positive? && v["target"].to_f.positive?
          (v["target"].to_f / v["current"].to_f)**(1.0 / years) - 1.0
        else
          a["valuation_reversion"].to_f
        end
      end

      def component_note(a, key, horizon)
        if a.dig("glide", key)
          "#{pct(a[key])} → #{pct(a.dig('glide', key))}"
        elsif key == "valuation_reversion" && a["valuation"].is_a?(Hash)
          "#{a['valuation']['current']}→#{a['valuation']['target']} over #{horizon || DEFAULT_HORIZON}y"
        end
      end

      def pct(v)
        "#{(v.to_f * 100).round(1)}%"
      end

      def data
        @data ||= YAML.safe_load(File.read(@path), permitted_classes: [], permitted_symbols: [], aliases: true)
      end
  end
end
