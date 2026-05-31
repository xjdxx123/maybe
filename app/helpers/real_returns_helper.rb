module RealReturnsHelper
  BENCHMARK_LABELS = {
    "sp500" => "S&P 500",
    "csi300" => "CSI 300",
    "gold" => "Gold",
    "deposit" => "Bank deposit",
    "govbond" => "Bonds (CN credit)",
    "real_estate" => "Real estate (approx)",
    "cpi" => "Inflation (CPI)",
    "You" => "Your portfolio"
  }.freeze

  # Annualized rate (a Float like 0.025) -> "2.5%/yr", or em dash if nil.
  def rr_pct_yr(rate)
    return "—" if rate.nil?

    "#{(rate * 100).round(1)}%/yr"
  end

  # Float amount in `currency` -> formatted money string, or em dash if nil.
  def rr_money(amount, currency)
    return "—" if amount.nil?

    Money.new(amount, currency).format(precision: 0)
  end

  def rr_benchmark_label(key)
    BENCHMARK_LABELS.fetch(key, key.to_s.humanize)
  end
end
