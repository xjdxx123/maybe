require "test_helper"

class RealReturn::CmaTest < ActiveSupport::TestCase
  def cma
    RealReturn::Cma.new(path: Rails.root.join("test", "fixtures", "files", "real_return", "cma.sample.yml"))
  end

  test "equity expected real return sums the building blocks" do
    # 0.025 - 0.005 + 0.030 + (-0.005) = 0.045
    assert_in_delta 0.045, cma.expected_real_return("equity_cn"), 1e-9
  end

  test "real estate expected real return sums its building blocks" do
    # 0.018 + 0.005 + (-0.013) = 0.010
    assert_in_delta 0.010, cma.expected_real_return("real_estate_cn"), 1e-9
  end

  test "bond / cash / gold / other use their direct real figures" do
    assert_in_delta 0.004, cma.expected_real_return("govbond"), 1e-9
    assert_in_delta(-0.003, cma.expected_real_return("deposit"), 1e-9)
    assert_in_delta 0.000, cma.expected_real_return("gold"), 1e-9
    assert_in_delta 0.010, cma.expected_real_return("other"), 1e-9
  end

  test "sigma and asset_classes are exposed; unknown class is nil" do
    assert_in_delta 0.20, cma.sigma("equity_cn"), 1e-9
    assert_includes cma.asset_classes, "gold"
    assert_nil cma.expected_real_return("nope")
    assert_nil cma.sigma("nope")
  end

  test "components exposes the raw building-block inputs" do
    c = cma.components("equity_cn")
    assert_equal "equity", c["kind"]
    assert_in_delta 0.025, c["dividend_yield"], 1e-9
    assert_nil cma.components("nope")
  end
end
