module RealReturn
  module ReferenceData
    # Loads annual reference series from YAML and interpolates by day-fraction.
    # Series shape: { "area_or_key" => { year(Integer) => level(Float) } }.
    # Region-keyed series (e.g. real_estate): { "key" => { "region" => { year => level } } }.
    class Bundled
      DEFAULT_CPI_PATH = Rails.root.join("config", "real_return", "cpi.yml")
      DEFAULT_BENCHMARKS_PATH = Rails.root.join("config", "real_return", "benchmarks.yml")

      def initialize(cpi_path: DEFAULT_CPI_PATH, benchmarks_path: DEFAULT_BENCHMARKS_PATH)
        @cpi_path = cpi_path
        @benchmarks_path = benchmarks_path
      end

      def cpi_index(area:, on:)
        interpolate(cpi_series(area), on)
      end

      def benchmark_level(key:, on:, region: nil)
        interpolate(benchmark_series(key, region), on)
      end

      def cpi_range(area:)
        series_range(cpi_series(area))
      end

      def benchmark_range(key:, region: nil)
        series_range(benchmark_series(key, region))
      end

      private
        def cpi_data
          @cpi_data ||= load_yaml(@cpi_path)
        end

        def benchmark_data
          @benchmark_data ||= load_yaml(@benchmarks_path)
        end

        def load_yaml(path)
          YAML.safe_load(File.read(path), permitted_classes: [], permitted_symbols: [], aliases: true)
        end

        def cpi_series(area)
          raw = cpi_data[area.to_s]
          raw && normalize_years(raw)
        end

        def benchmark_series(key, region)
          raw = benchmark_data[key.to_s]
          return nil if raw.nil?

          # Region-keyed series (e.g. real_estate) nest one more level: { region => { year => level } }.
          if raw.values.first.is_a?(Hash)
            return nil if region.nil?

            raw = raw[region.to_s]
            return nil if raw.nil?
          end

          normalize_years(raw)
        end

        def normalize_years(hash)
          hash.transform_keys(&:to_i).transform_values(&:to_f)
        end

        def series_range(series)
          return nil if series.nil? || series.empty?

          years = series.keys
          Date.new(years.min, 1, 1)..Date.new(years.max, 1, 1)
        end

        # Linear interpolation by day-fraction between consecutive years.
        # Before the earliest year -> nil (out of range). On/after the latest year
        # -> clamp to the latest level (handles the current, partial year).
        def interpolate(series, on)
          return nil if series.nil? || series.empty?

          min_year = series.keys.min
          max_year = series.keys.max
          return nil if on < Date.new(min_year, 1, 1)
          return series[max_year] if on >= Date.new(max_year, 1, 1)

          y = on.year
          lo = series[y]
          hi = series[y + 1]
          return nil if lo.nil? || hi.nil?

          year_start = Date.new(y, 1, 1)
          next_start = Date.new(y + 1, 1, 1)
          fraction = (on - year_start).to_f / (next_start - year_start).to_f
          lo + fraction * (hi - lo)
        end
    end
  end
end
