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

  test "breakdown decomposes equity into signed contributions that sum to the expected real return" do
    bd = cma.breakdown("equity_cn")
    assert_equal %w[dividend_yield net_dilution real_earnings_growth valuation_reversion], bd.map { |c| c[:key] }

    dilution = bd.find { |c| c[:key] == "net_dilution" }
    # stored +0.005 but SUBTRACTED in the formula -> contribution is negative
    assert_in_delta(-0.005, dilution[:contribution], 1e-9)
    assert_equal "Net dilution / buybacks", dilution[:label]

    assert_equal :observable, bd.find { |c| c[:key] == "dividend_yield" }[:type]
    assert_equal :assumption, bd.find { |c| c[:key] == "real_earnings_growth" }[:type]

    # rows must sum to the headline number
    assert_in_delta cma.expected_real_return("equity_cn"), bd.sum { |c| c[:contribution] }, 1e-9
  end

  test "breakdown handles a non-equity kind: positive signs, shared valuation key, sums to total" do
    bd = cma.breakdown("real_estate_cn")
    assert_equal %w[net_rental_yield real_rent_growth valuation_reversion], bd.map { |c| c[:key] }
    # all added as-is (no negation): 0.018 + 0.005 + (-0.013)
    assert_in_delta 0.018, bd.find { |c| c[:key] == "net_rental_yield" }[:contribution], 1e-9
    assert_in_delta(-0.013, bd.find { |c| c[:key] == "valuation_reversion" }[:contribution], 1e-9)
    assert_equal :assumption, bd.find { |c| c[:key] == "valuation_reversion" }[:type]
    assert_in_delta cma.expected_real_return("real_estate_cn"), bd.sum { |c| c[:contribution] }, 1e-9
  end

  test "breakdown surfaces per-input source text, nil when absent" do
    bd = cma.breakdown("equity_cn")
    assert_equal "sample dividend source", bd.find { |c| c[:key] == "dividend_yield" }[:source]
    assert_nil bd.find { |c| c[:key] == "net_dilution" }[:source]
  end

  test "breakdown is empty for an unknown class" do
    assert_equal [], cma.breakdown("nope")
  end

  test "metadata returns the YAML metadata hash, or empty when absent" do
    # sample fixture has no metadata block
    assert_equal({}, cma.metadata)
  end
end
