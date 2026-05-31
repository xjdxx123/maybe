module RealReturn
  # Places a net worth (base currency, today's money) on a wealth distribution and
  # returns a percentile (log-linear interpolation between [pct, threshold] points,
  # clamped at the ends) plus a tier label, for China national (CN) and global (WLD).
  class WealthTier
    DEFAULT_PATH = Rails.root.join("config", "real_return", "wealth_distribution.yml")

    def initialize(path: DEFAULT_PATH)
      @path = path
    end

    # Percentile (0-100) of `net_worth` within `region`'s distribution, or nil if unavailable.
    def percentile(net_worth, region:)
      points = series(region)
      return nil if points.nil? || points.empty? || net_worth <= 0

      return points.first[0] if net_worth <= points.first[1]
      return points.last[0] if net_worth >= points.last[1]

      points.each_cons(2) do |(p0, t0), (p1, t1)|
        next if net_worth > t1

        frac = (Math.log(net_worth) - Math.log(t0)) / (Math.log(t1) - Math.log(t0))
        return p0 + (p1 - p0) * frac
      end
      points.last[0]
    end

    # Human tier label from a percentile.
    def tier_label(pct)
      return nil if pct.nil?

      case
      when pct >= 99 then "Top 1%"
      when pct >= 95 then "Top 5%"
      when pct >= 90 then "Top 10%"
      when pct >= 75 then "Top 25%"
      when pct >= 50 then "Above median"
      else "Below median"
      end
    end

    # { cn: { percentile:, label: }, global: { percentile:, label: } }
    def placement(net_worth)
      { cn: tier_for(net_worth, "CN"), global: tier_for(net_worth, "WLD") }
    end

    private
      def tier_for(net_worth, region)
        pct = percentile(net_worth, region: region)
        { percentile: pct, label: tier_label(pct) }
      end

      # Ascending [percentile(Float), threshold(Float)] points for a region, or nil.
      def series(region)
        raw = data[region.to_s]
        return nil if raw.nil?

        raw.map { |pct, threshold| [ pct.to_f, threshold.to_f ] }.sort_by(&:last)
      end

      def data
        @data ||= YAML.safe_load(File.read(@path), permitted_classes: [], permitted_symbols: [], aliases: true)
      end
  end
end
