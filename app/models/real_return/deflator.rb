module RealReturn
  # Measures "real" return against one of three inflation lenses:
  #   :cpi         consumer prices (cost of living)
  #   :m2          broad money growth (your share of total money)
  #   :house_price the regional home-price index (asset inflation)
  # Each lens is a level series; its annualized growth is the inflation rate,
  # and real return follows the Fisher equation.
  class Deflator
    LENSES = %i[cpi m2 house_price].freeze

    def initialize(currency:, reference_data: ReferenceData.default)
      @currency = currency
      @reference_data = reference_data
    end

    # Annualized inflation (Actual/365) under `lens` over [from, to]. nil if unavailable.
    def annualized(lens:, from:, to:)
      v0, v1 = endpoints(lens, from, to)
      days = (to - from).to_i
      return nil if v0.nil? || v1.nil? || v0 <= 0 || days <= 0

      (v1 / v0)**(365.0 / days) - 1.0
    end

    # Inflation-adjusted real return under `lens` (Fisher). nil if unavailable.
    def real_return(nominal:, lens:, from:, to:)
      rate = annualized(lens: lens, from: from, to: to)
      return nil if rate.nil?

      (1.0 + nominal) / (1.0 + rate) - 1.0
    end

    private
      def endpoints(lens, from, to)
        case lens
        when :cpi
          area = Region.cpi_area(@currency)
          [ @reference_data.cpi_index(area: area, on: from), @reference_data.cpi_index(area: area, on: to) ]
        when :m2
          area = Region.cpi_area(@currency)
          [ @reference_data.m2_index(area: area, on: from), @reference_data.m2_index(area: area, on: to) ]
        when :house_price
          region = Region.real_estate(@currency)
          [ @reference_data.benchmark_level(key: "real_estate", on: from, region: region),
            @reference_data.benchmark_level(key: "real_estate", on: to, region: region) ]
        else
          [ nil, nil ]
        end
      end
  end
end
