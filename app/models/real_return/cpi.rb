module RealReturn
  # Inflation math over a CPI index. Annualization uses Actual/365.
  class Cpi
    def initialize(reference_data: ReferenceData.default)
      @reference_data = reference_data
    end

    # Annualized inflation for `area` between two dates. nil if data unavailable.
    def annualized(area:, from:, to:)
      i0 = @reference_data.cpi_index(area: area, on: from)
      i1 = @reference_data.cpi_index(area: area, on: to)
      days = (to - from).to_i
      return nil if i0.nil? || i1.nil? || i0 <= 0 || days <= 0

      (i1 / i0)**(365.0 / days) - 1.0
    end

    # Inflation-adjusted annualized return. nil if inflation unavailable.
    def real_return(nominal:, area:, from:, to:)
      inflation = annualized(area: area, from: from, to: to)
      return nil if inflation.nil?

      self.class.fisher(nominal: nominal, inflation: inflation)
    end

    # true/false whether the nominal rate beat inflation; nil if unavailable.
    def beats_inflation?(nominal:, area:, from:, to:)
      inflation = annualized(area: area, from: from, to: to)
      return nil if inflation.nil?

      nominal > inflation
    end

    # Pure Fisher equation: (1 + nominal) / (1 + inflation) - 1.
    def self.fisher(nominal:, inflation:)
      (1.0 + nominal) / (1.0 + inflation) - 1.0
    end
  end
end
