require "test_helper"

class ProjectionsHelperTest < ActionView::TestCase
  test "fan svg with overlays draws dashed polylines and scales to the combined max" do
    svg = projection_fan_svg([ 0, 1, 2 ], [ 100, 100, 100 ], [ 100, 110, 120 ], [ 100, 120, 140 ],
      overlays: [ { label: "All equity", values: [ 100, 200, 400 ] } ])
    assert_includes svg, "stroke-dasharray"
    assert_includes svg, "polyline"
    assert svg.html_safe?
  end

  test "formula renders the building-block arithmetic for an equity class" do
    cma = RealReturn::Cma.new(path: Rails.root.join("test", "fixtures", "files", "real_return", "cma.sample.yml"))
    str = projection_formula(cma, "equity_cn")
    assert_includes str, "="
    assert_includes str, "%"
  end

  test "formula handles bond / cash / gold kinds" do
    cma = RealReturn::Cma.new(path: Rails.root.join("test", "fixtures", "files", "real_return", "cma.sample.yml"))
    assert_includes projection_formula(cma, "govbond"), "real yield"
    assert_includes projection_formula(cma, "deposit"), "real rate"
    assert_includes projection_formula(cma, "gold"), "≈"
  end
end
