module RealReturn
  # Capital Market Assumptions: expected REAL return (neutral) and volatility per
  # asset class, from documented, editable building-block inputs (config/real_return/cma.yml).
  class Cma
    DEFAULT_PATH = Rails.root.join("config", "real_return", "cma.yml")

    def initialize(path: DEFAULT_PATH)
      @path = path
    end

    def asset_classes
      data.keys
    end

    # Expected real return for `asset_class`, summed from its building blocks. nil if unknown.
    def expected_real_return(asset_class)
      a = data[asset_class.to_s]
      return nil if a.nil?

      case a["kind"]
      when "equity"
        a["dividend_yield"].to_f - a["net_dilution"].to_f + a["real_earnings_growth"].to_f + a["valuation_reversion"].to_f
      when "real_estate"
        a["net_rental_yield"].to_f + a["real_rent_growth"].to_f + a["valuation_reversion"].to_f
      when "bond"
        a["real_yield"].to_f
      when "cash"
        a["real_rate"].to_f
      else # gold, other
        a["real_return"].to_f
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

    private
      def data
        @data ||= YAML.safe_load(File.read(@path), permitted_classes: [], permitted_symbols: [], aliases: true)
      end
  end
end
