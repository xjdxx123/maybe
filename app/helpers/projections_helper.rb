module ProjectionsHelper
  # Server-rendered SVG fan chart: shaded p15..p85 band + p50 median line.
  # years/p15/p50/p85 are parallel arrays. Returns an html_safe SVG string.
  def projection_fan_svg(years, p15, p50, p85, width: 640, height: 220, pad: 6)
    n = years.size
    max = p85.max.to_f
    return "".html_safe if n < 2 || max <= 0

    xs = ->(i) { (pad + (width - 2 * pad) * (i.to_f / (n - 1))).round(1) }
    ys = ->(v) { (height - pad - (height - 2 * pad) * (v.to_f / max)).round(1) }

    top = (0...n).map { |i| "#{xs.call(i)},#{ys.call(p85[i])}" }
    bottom = (n - 1).downto(0).map { |i| "#{xs.call(i)},#{ys.call(p15[i])}" }
    band = (top + bottom).join(" ")
    median = (0...n).map { |i| "#{xs.call(i)},#{ys.call(p50[i])}" }.join(" ")

    <<~SVG.html_safe
      <svg viewBox="0 0 #{width} #{height}" class="w-full text-success" role="img" aria-label="Projection fan chart">
        <polygon points="#{band}" fill="currentColor" fill-opacity="0.15" />
        <polyline points="#{median}" fill="none" stroke="currentColor" stroke-width="2" />
      </svg>
    SVG
  end

  # Unique asset-class keys present in the projection basket, in stable order.
  def projection_asset_classes(assets)
    assets.map { |a| a[:asset_class] }.uniq
  end
end
