module ProjectionsHelper
  OVERLAY_COLORS = %w[#2563eb #d97706 #7c3aed #0891b2 #db2777].freeze

  # Server-rendered SVG fan: shaded p15..p85 band + p50 median line + optional dashed
  # overlay median lines. overlays: [{ label:, values: [..] }]. Returns an html_safe SVG.
  def projection_fan_svg(years, p15, p50, p85, overlays: [], width: 640, height: 220, pad: 6)
    n = years.size
    max = ([ p85.max ] + overlays.map { |o| o[:values].max }).map(&:to_f).max
    return "".html_safe if n < 2 || max <= 0

    xs = ->(i) { (pad + (width - 2 * pad) * (i.to_f / (n - 1))).round(1) }
    ys = ->(v) { (height - pad - (height - 2 * pad) * (v.to_f / max)).round(1) }
    pts = ->(arr) { (0...n).map { |i| "#{xs.call(i)},#{ys.call(arr[i])}" }.join(" ") }

    band = ((0...n).map { |i| "#{xs.call(i)},#{ys.call(p85[i])}" } +
            (n - 1).downto(0).map { |i| "#{xs.call(i)},#{ys.call(p15[i])}" }).join(" ")

    overlay_svg = overlays.each_with_index.map do |o, idx|
      %(<polyline points="#{pts.call(o[:values])}" fill="none" stroke="#{OVERLAY_COLORS[idx % OVERLAY_COLORS.size]}" stroke-width="1.5" stroke-dasharray="4 3" />)
    end.join("\n")

    <<~SVG.html_safe
      <svg viewBox="0 0 #{width} #{height}" class="w-full text-success" role="img" aria-label="Projection fan chart">
        <polygon points="#{band}" fill="currentColor" fill-opacity="0.15" />
        <polyline points="#{pts.call(p50)}" fill="none" stroke="currentColor" stroke-width="2" />
        #{overlay_svg}
      </svg>
    SVG
  end

  # Color for the Nth overlay (to label the legend/table consistently with the chart).
  def projection_overlay_color(index)
    OVERLAY_COLORS[index % OVERLAY_COLORS.size]
  end

  def projection_asset_classes(assets)
    assets.map { |a| a[:asset_class] }.uniq
  end

  # Human, traceable building-block formula for an asset class, e.g.
  # "dividend 2.8% − dilution 1.0% + real growth 3.5% + valuation 0.0% = 5.3%/yr". Uses Cma#components.
  def projection_formula(cma, asset_class)
    c = cma.components(asset_class)
    er = cma.expected_real_return(asset_class)
    return "—" if c.nil? || er.nil?

    pct = ->(v) { "#{(v.to_f * 100).round(1)}%" }
    body =
      case c["kind"]
      when "equity"
        "dividend #{pct.call(c['dividend_yield'])} − dilution #{pct.call(c['net_dilution'])} + real growth #{pct.call(c['real_earnings_growth'])} + valuation #{pct.call(c['valuation_reversion'])}"
      when "real_estate"
        "rental yield #{pct.call(c['net_rental_yield'])} + real rent growth #{pct.call(c['real_rent_growth'])} + valuation #{pct.call(c['valuation_reversion'])}"
      when "bond"
        "real yield #{pct.call(c['real_yield'])}"
      when "cash"
        "real rate #{pct.call(c['real_rate'])}"
      else
        "≈ #{pct.call(c['real_return'])} (golden constant / assumption)"
      end
    "#{body} = #{pct.call(er)}/yr"
  end
end
