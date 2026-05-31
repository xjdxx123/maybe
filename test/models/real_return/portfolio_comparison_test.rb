require "test_helper"

class RealReturn::PortfolioComparisonTest < ActiveSupport::TestCase
  include LedgerTestingHelper

  def cma
    RealReturn::Cma.new(path: Rails.root.join("test", "fixtures", "files", "real_return", "cma.sample.yml"))
  end

  def family_with_property
    family = families(:empty)
    family.update!(currency: "CNY")
    create_account_with_ledger(
      account: { type: Property, currency: "CNY", balance: 0 },
      entries: [
        { type: "opening_anchor", date: Date.new(2010, 1, 1), balance: 1_000_000 },
        { type: "current_anchor", date: Date.new(2024, 1, 1), balance: 2_000_000 }
      ]
    )
    family
  end

  test "rows include Current plus the presets, each with ordered terminals" do
    comp = RealReturn::PortfolioComparison.new(family_with_property, as_of: Date.new(2024, 1, 1),
      horizon: 20, cma: cma, paths: 1500, seed: 9)
    rows = comp.rows

    assert_equal "Current", rows.first[:name]
    names = rows.map { |r| r[:name] }
    assert_includes names, "All equity"
    assert_includes names, "All cash"
    rows.each do |r|
      assert_equal 21, r[:median].size # horizon + 1
      assert r[:terminal][:p15] <= r[:terminal][:p50]
      assert r[:terminal][:p50] <= r[:terminal][:p85]
    end
  end

  test "all-cash row expected real return equals the deposit CMA" do
    comp = RealReturn::PortfolioComparison.new(family_with_property, as_of: Date.new(2024, 1, 1),
      horizon: 10, cma: cma, paths: 1000, seed: 9)
    cash_row = comp.rows.find { |r| r[:name] == "All cash" }
    assert_in_delta(-0.003, cash_row[:expected_real_return], 1e-9)
  end

  test "custom weights add a Custom row" do
    comp = RealReturn::PortfolioComparison.new(family_with_property, as_of: Date.new(2024, 1, 1),
      horizon: 10, custom_weights: { equity: 0.5, bonds: 0.5 }, cma: cma, paths: 1000, seed: 9)
    assert_includes comp.rows.map { |r| r[:name] }, "Custom"
  end

  test "referenced_asset_classes unions held holdings with every model-portfolio class" do
    comp = RealReturn::PortfolioComparison.new(family_with_property, as_of: Date.new(2024, 1, 1),
      horizon: 10, cma: cma, paths: 500, seed: 9)
    classes = comp.referenced_asset_classes

    # held: only a property -> real_estate_cn; presets add equity / bonds / gold / cash
    assert_includes classes, "real_estate_cn"
    assert_includes classes, "equity_cn"
    assert_includes classes, "govbond"
    assert_includes classes, "gold"
    assert_includes classes, "deposit"
    assert_equal classes, classes.uniq
  end
end
