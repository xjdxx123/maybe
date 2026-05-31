require "test_helper"

class RealReturn::DeflatorTest < ActiveSupport::TestCase
  def ref
    dir = Rails.root.join("test", "fixtures", "files", "real_return")
    RealReturn::ReferenceData::Bundled.new(
      cpi_path: dir.join("cpi.sample.yml"),
      benchmarks_path: dir.join("benchmarks.sample.yml"),
      m2_path: dir.join("m2.sample.yml")
    )
  end

  def deflator
    RealReturn::Deflator.new(currency: "CNY", reference_data: ref)
  end

  test "cpi lens annualizes the CPI series" do
    # CN CPI 100 -> 110 over 730 days => 1.1**(365/730) - 1 ~= 0.04881
    rate = deflator.annualized(lens: :cpi, from: Date.new(2010, 1, 1), to: Date.new(2012, 1, 1))
    assert_in_delta 0.04881, rate, 1e-4
  end

  test "m2 lens annualizes the M2 series" do
    # CN M2 100 -> 121 over 730 days => 1.21**(365/730) - 1 = 0.10
    rate = deflator.annualized(lens: :m2, from: Date.new(2010, 1, 1), to: Date.new(2012, 1, 1))
    assert_in_delta 0.10, rate, 1e-4
  end

  test "house_price lens annualizes the real_estate series for the currency's region" do
    # real_estate CN sample 1.00 -> 1.21 over 730 days => 0.10
    rate = deflator.annualized(lens: :house_price, from: Date.new(2010, 1, 1), to: Date.new(2012, 1, 1))
    assert_in_delta 0.10, rate, 1e-4
  end

  test "real_return deflates the nominal rate by the chosen lens" do
    # nominal 0.10 vs M2 inflation 0.10 => real ~ 0
    real = deflator.real_return(nominal: 0.10, lens: :m2, from: Date.new(2010, 1, 1), to: Date.new(2012, 1, 1))
    assert_in_delta 0.0, real, 1e-4
  end

  test "returns nil when the lens series is unavailable" do
    eur = RealReturn::Deflator.new(currency: "EUR", reference_data: ref) # EUR -> cpi_area WLD (no M2)
    assert_nil eur.annualized(lens: :m2, from: Date.new(2010, 1, 1), to: Date.new(2012, 1, 1))
  end

  test "LENSES lists the three deflators" do
    assert_equal %i[cpi m2 house_price], RealReturn::Deflator::LENSES
  end
end
