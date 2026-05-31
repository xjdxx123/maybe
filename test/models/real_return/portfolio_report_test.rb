require "test_helper"

class RealReturn::PortfolioReportTest < ActiveSupport::TestCase
  include LedgerTestingHelper

  def ref
    dir = Rails.root.join("test", "fixtures", "files", "real_return")
    RealReturn::ReferenceData::Bundled.new(
      cpi_path: dir.join("cpi.sample.yml"),
      benchmarks_path: dir.join("benchmarks.sample.yml")
    )
  end

  test "aggregates in-scope asset accounts and ranks a league table" do
    family = families(:empty)
    family.update!(currency: "CNY")

    create_account_with_ledger(
      account: { type: Property, currency: "CNY", balance: 0 },
      entries: [
        { type: "opening_anchor", date: Date.new(2010, 1, 1), balance: 1_000_000 },
        { type: "current_anchor", date: Date.new(2012, 1, 1), balance: 1_440_000 }
      ]
    )

    report = RealReturn::PortfolioReport.new(family, as_of: Date.new(2012, 1, 1), reference_data: ref)

    assert report.analyses.one?
    assert_in_delta 0.20, report.nominal_return, 1e-3
    assert_equal "CN", report.cpi_area
    labels = report.league_table.map(&:first)
    assert_includes labels, "You"
    assert_includes labels, "sp500"
    assert_includes labels, "cpi"
    # league is ranked high -> low; the first row's value is the max present
    values = report.league_table.map(&:last).compact
    assert_equal values.max, report.league_table.first.last
  end

  test "Account#real_return returns an Analysis" do
    account = create_account_with_ledger(
      account: { type: Property, currency: "USD", balance: 0 },
      entries: [ { type: "opening_anchor", date: Date.new(2010, 1, 1), balance: 1000 } ]
    )
    assert_instance_of RealReturn::Analysis, account.real_return(as_of: Date.new(2012, 1, 1))
  end

  test "Family#real_return_report returns a PortfolioReport" do
    assert_instance_of RealReturn::PortfolioReport, families(:empty).real_return_report
  end
end
