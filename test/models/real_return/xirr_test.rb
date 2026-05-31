require "test_helper"

class RealReturn::XirrTest < ActiveSupport::TestCase
  test "single in/out over one calendar year returns the simple rate" do
    flows = [ [ Date.new(2021, 1, 1), -1000.0 ], [ Date.new(2022, 1, 1), 1100.0 ] ]
    assert_in_delta 0.10, RealReturn::Xirr.compute(flows), 1e-4
  end

  test "multiple contributions converge to a positive rate" do
    # -1000 @ y0, -1000 @ y1, +2300 @ y2 solves 2300x^2 - 1000x - 1000 = 0 => r ~= 0.097
    flows = [
      [ Date.new(2020, 1, 1), -1000.0 ],
      [ Date.new(2021, 1, 1), -1000.0 ],
      [ Date.new(2022, 1, 1), 2300.0 ]
    ]
    rate = RealReturn::Xirr.compute(flows)
    assert rate > 0.08 && rate < 0.11, "expected ~0.097, got #{rate}"
  end

  test "returns nil when fewer than two flows" do
    assert_nil RealReturn::Xirr.compute([ [ Date.new(2021, 1, 1), -1000.0 ] ])
  end

  test "returns nil when all flows share a sign" do
    flows = [ [ Date.new(2021, 1, 1), -1000.0 ], [ Date.new(2022, 1, 1), -500.0 ] ]
    assert_nil RealReturn::Xirr.compute(flows)
  end

  test "near-total-loss exercises the bisection fallback" do
    # Newton overshoots below -1 and breaks; bisection on [-0.9999, 10] finds the root.
    # -1000 -> +1 over one year solves (1+r) = 1/1000 => r ~= -0.999
    flows = [ [ Date.new(2010, 1, 1), -1000.0 ], [ Date.new(2011, 1, 1), 1.0 ] ]
    rate = RealReturn::Xirr.compute(flows)
    assert rate < -0.99, "expected ~ -0.999, got #{rate}"
  end
end
