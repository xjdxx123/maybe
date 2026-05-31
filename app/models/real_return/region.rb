module RealReturn
  # Maps a family base currency to the CPI / real-estate region used for lookups,
  # and holds the canonical benchmark key list.
  module Region
    BY_CURRENCY = { "CNY" => "CN", "USD" => "US" }.freeze
    BENCHMARK_KEYS = %w[sp500 csi300 gold deposit govbond real_estate].freeze

    module_function

    def cpi_area(currency)
      BY_CURRENCY.fetch(currency, "WLD")
    end

    # real_estate data only exists for CN and US; default everything else to US.
    def real_estate(currency)
      BY_CURRENCY.fetch(currency, "US")
    end

    # Region argument for a benchmark lookup: only real_estate is region-keyed.
    def for_benchmark(key, currency)
      key == "real_estate" ? real_estate(currency) : nil
    end
  end
end
