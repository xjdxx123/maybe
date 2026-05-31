require "test_helper"

class RealReturn::AnalysisTest < ActiveSupport::TestCase
  include LedgerTestingHelper

  # Reference data with known synthetic series (from Phase 1 fixtures), so metric
  # assertions are deterministic. Series cover 2010..2012.
  def ref
    dir = Rails.root.join("test", "fixtures", "files", "real_return")
    RealReturn::ReferenceData::Bundled.new(
      cpi_path: dir.join("cpi.sample.yml"),
      benchmarks_path: dir.join("benchmarks.sample.yml")
    )
  end

  test "property with purchase and current valuation computes nominal CAGR" do
    account = create_account_with_ledger(
      account: { type: Property, currency: "CNY", balance: 0 },
      entries: [
        { type: "opening_anchor", date: Date.new(2010, 1, 1), balance: 1_000_000 },
        { type: "current_anchor", date: Date.new(2012, 1, 1), balance: 1_440_000 }
      ]
    )
    analysis = RealReturn::Analysis.new(account, as_of: Date.new(2012, 1, 1), base_currency: "CNY", reference_data: ref)

    assert_not analysis.estimated?
    # 1.0M -> 1.44M over 730 days => 1.44**(365/730) - 1 = 0.20
    assert_in_delta 0.20, analysis.nominal_return, 1e-3
    assert analysis.has_data?
  end

  test "property with only a purchase estimates current value from the house index" do
    # real_estate CN sample: 2010 -> 2012 grows 1.00 -> 1.21, so 1.0M -> ~1.21M
    account = create_account_with_ledger(
      account: { type: Property, currency: "CNY", balance: 0 },
      entries: [ { type: "opening_anchor", date: Date.new(2010, 1, 1), balance: 1_000_000 } ]
    )
    analysis = RealReturn::Analysis.new(account, as_of: Date.new(2012, 1, 1), base_currency: "CNY", reference_data: ref)

    assert analysis.estimated?
    # 1.21**(365/730) - 1 = 0.10
    assert_in_delta 0.10, analysis.nominal_return, 1e-3
  end

  test "investment account derives terminal from holdings and flows from trades" do
    account = create_account_with_ledger(
      account: { type: Investment, currency: "USD", balance: 0 },
      entries: [ { type: "trade", date: Date.new(2010, 1, 1), ticker: "ACME", qty: 10, price: 100 } ],
      holdings: [ { ticker: "ACME", date: Date.new(2012, 1, 1), qty: 10, price: 150, amount: 1500 } ]
    )
    analysis = RealReturn::Analysis.new(account, as_of: Date.new(2012, 1, 1), base_currency: "USD", reference_data: ref)

    # bought 1000, now worth 1500 over 730 days => 1.5**(365/730) - 1 = 0.2247
    assert_in_delta 0.2247, analysis.nominal_return, 1e-3
    assert_equal [ [ Date.new(2010, 1, 1), 1000.0 ] ], analysis.contributions
  end

  test "real_return and beats_inflation use CPI for the base currency" do
    account = create_account_with_ledger(
      account: { type: Property, currency: "CNY", balance: 0 },
      entries: [
        { type: "opening_anchor", date: Date.new(2010, 1, 1), balance: 1_000_000 },
        { type: "current_anchor", date: Date.new(2012, 1, 1), balance: 1_440_000 }
      ]
    )
    analysis = RealReturn::Analysis.new(account, as_of: Date.new(2012, 1, 1), base_currency: "CNY", reference_data: ref)

    # nominal ~0.20, CN inflation ~0.0488 => real ~ (1.20/1.0488)-1 ~= 0.1440
    assert_in_delta 0.144, analysis.real_return, 5e-3
    assert_equal true, analysis.beats_inflation?
  end

  test "benchmark_returns gives a counterfactual rate per key" do
    account = create_account_with_ledger(
      account: { type: Property, currency: "CNY", balance: 0 },
      entries: [
        { type: "opening_anchor", date: Date.new(2010, 1, 1), balance: 1_000_000 },
        { type: "current_anchor", date: Date.new(2012, 1, 1), balance: 1_440_000 }
      ]
    )
    analysis = RealReturn::Analysis.new(account, as_of: Date.new(2012, 1, 1), base_currency: "CNY", reference_data: ref)
    returns = analysis.benchmark_returns

    assert_equal RealReturn::Region::BENCHMARK_KEYS.sort, returns.keys.sort
    # sp500 sample 1.0 -> 1.5 => 0.2247 counterfactual on the single 2010 contribution
    assert_in_delta 0.2247, returns["sp500"], 1e-3
  end
end
