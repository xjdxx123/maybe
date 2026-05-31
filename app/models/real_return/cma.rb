module RealReturn
  # Capital Market Assumptions: expected REAL return (neutral) and volatility per
  # asset class, from documented, editable building-block inputs (config/real_return/cma.yml).
  class Cma
    DEFAULT_PATH = Rails.root.join("config", "real_return", "cma.yml")

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

    def asset_classes
      data.keys
    end

    # Expected real return for `asset_class`, summed from its building blocks. nil if unknown.
    def expected_real_return(asset_class)
      cs = contributions(asset_class)
      return nil if cs.nil?

      cs.sum(0.0) { |_key, value| value }
    end

    # Ordered, decorated building blocks whose contributions sum to expected_real_return:
    # [{ key:, label:, type:, contribution:, source: }]. Empty for an unknown class.
    def breakdown(asset_class)
      cs = contributions(asset_class)
      return [] if cs.nil?

      a = data[asset_class.to_s]
      cs.map do |key, value|
        meta = COMPONENTS[key] || { label: key, type: :assumption }
        { key: key, label: meta[:label], type: meta[:type], contribution: value, source: a.dig("sources", key) }
      end
    end

    # Annualized volatility (σ) for `asset_class`, or nil if unknown.
    def sigma(asset_class)
      a = data[asset_class.to_s]
      a && a["sigma"]&.to_f
    end

    # Raw building-block inputs for an asset class (Hash with string keys), or nil.
    def components(asset_class)
      data[asset_class.to_s]
    end

    # File-level metadata (approach, as_of, sources), or {} if absent.
    def metadata
      data["metadata"] || {}
    end

    private
      # The formula as data: ordered [component_key, signed_contribution]. nil if class unknown.
      # SINGLE SOURCE OF TRUTH — expected_real_return sums it, breakdown decorates it, so the
      # displayed rows always add up to the headline number. net_dilution is SUBTRACTED.
      def contributions(asset_class)
        a = data[asset_class.to_s]
        return nil if a.nil?

        case a["kind"]
        when "equity"
          [ [ "dividend_yield", a["dividend_yield"].to_f ],
            [ "net_dilution", -a["net_dilution"].to_f ],
            [ "real_earnings_growth", a["real_earnings_growth"].to_f ],
            [ "valuation_reversion", a["valuation_reversion"].to_f ] ]
        when "real_estate"
          [ [ "net_rental_yield", a["net_rental_yield"].to_f ],
            [ "real_rent_growth", a["real_rent_growth"].to_f ],
            [ "valuation_reversion", a["valuation_reversion"].to_f ] ]
        when "bond" then [ [ "real_yield", a["real_yield"].to_f ] ]
        when "cash" then [ [ "real_rate", a["real_rate"].to_f ] ]
        else             [ [ "real_return", a["real_return"].to_f ] ]
        end
      end

      def data
        @data ||= YAML.safe_load(File.read(@path), permitted_classes: [], permitted_symbols: [], aliases: true)
      end
  end
end
