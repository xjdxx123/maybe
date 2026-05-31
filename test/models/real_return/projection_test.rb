require "test_helper"

class RealReturn::ProjectionTest < ActiveSupport::TestCase
  include LedgerTestingHelper

  def cma
    RealReturn::Cma.new(path: Rails.root.join("test", "fixtures", "files", "real_return", "cma.sample.yml"))
  end

  test "assembles in-scope accounts into assets with CMA inputs" do
    family = families(:empty)
    family.update!(currency: "CNY")
    create_account_with_ledger(
      account: { type: Property, currency: "CNY", balance: 0 },
      entries: [
        { type: "opening_anchor", date: Date.new(2010, 1, 1), balance: 1_000_000 },
        { type: "current_anchor", date: Date.new(2024, 1, 1), balance: 2_000_000 }
      ]
    )
    projection = RealReturn::Projection.new(family, as_of: Date.new(2024, 1, 1), cma: cma)

    assets = projection.assets(horizon: 30)
    assert_equal 1, assets.size
    a = assets.first
    assert_equal "real_estate_cn", a[:asset_class]
    assert_in_delta 2_000_000.0, a[:value], 1.0
    assert a[:expected_real_return]
    assert a[:sigma]
  end

  test "project returns ordered real bands starting at current basket value" do
    family = families(:empty)
    family.update!(currency: "CNY")
    create_account_with_ledger(
      account: { type: Property, currency: "CNY", balance: 0 },
      entries: [
        { type: "opening_anchor", date: Date.new(2010, 1, 1), balance: 1_000_000 },
        { type: "current_anchor", date: Date.new(2024, 1, 1), balance: 2_000_000 }
      ]
    )
    projection = RealReturn::Projection.new(family, as_of: Date.new(2024, 1, 1), cma: cma, paths: 2000, seed: 7)

    out = projection.project(horizon: 20)
    assert_equal (0..20).to_a, out[:years]
    assert_in_delta 2_000_000.0, out[:p50][0], 1.0
    assert out[:p15][20] <= out[:p50][20]
    assert out[:p50][20] <= out[:p85][20]
  end

  test "empty family projects an empty basket gracefully" do
    out = RealReturn::Projection.new(families(:empty), as_of: Date.current, cma: cma).project(horizon: 10)
    assert_equal Array.new(11, 0.0), out[:p50]
  end

  test "includes single-snapshot OtherAssets and Depository cash in the basket" do
    family = families(:empty)
    family.update!(currency: "CNY")
    create_account_with_ledger(
      account: { type: OtherAsset, currency: "CNY", balance: 0 },
      entries: [ { type: "current_anchor", date: Date.new(2024, 1, 1), balance: 1_500_000 } ]
    )
    create_account_with_ledger(
      account: { type: Depository, currency: "CNY", balance: 0 },
      entries: [ { type: "current_anchor", date: Date.new(2024, 1, 1), balance: 600_000 } ]
    )
    projection = RealReturn::Projection.new(family, as_of: Date.new(2024, 1, 1), cma: cma)

    assert_equal %w[deposit other], projection.assets(horizon: 10).map { |a| a[:asset_class] }.sort
    assert_in_delta 2_100_000.0, projection.assets(horizon: 10).sum { |a| a[:value] }, 1.0
  end

  def family_with_one_asset
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

  test "assets carry horizon-aware mean and regime fields" do
    proj = RealReturn::Projection.new(family_with_one_asset, as_of: Date.new(2024, 1, 1),
      cma: RealReturn::Cma.new(path: Rails.root.join("test", "fixtures", "files", "real_return", "cma.sample.yml")))
    a = proj.assets(horizon: 20).first
    assert a.key?(:mean_start)
    assert a.key?(:mean_end)
    assert a.key?(:regime_offsets)
    assert a.key?(:sigma)
  end
end
