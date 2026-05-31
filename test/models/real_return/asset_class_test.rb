require "test_helper"

class RealReturn::AssetClassTest < ActiveSupport::TestCase
  # Lightweight stand-in for an Account (only accountable_type is read).
  Acct = Struct.new(:accountable_type)

  test "maps accountable types to class keys using the family region" do
    assert_equal "real_estate_cn", RealReturn::AssetClass.for(Acct.new("Property"), currency: "CNY")
    assert_equal "equity_cn", RealReturn::AssetClass.for(Acct.new("Investment"), currency: "CNY")
    assert_equal "real_estate_us", RealReturn::AssetClass.for(Acct.new("Property"), currency: "USD")
    assert_equal "equity_us", RealReturn::AssetClass.for(Acct.new("Investment"), currency: "USD")
  end

  test "non-regional classes ignore region" do
    assert_equal "crypto", RealReturn::AssetClass.for(Acct.new("Crypto"), currency: "CNY")
    assert_equal "deposit", RealReturn::AssetClass.for(Acct.new("Depository"), currency: "CNY")
    assert_equal "other", RealReturn::AssetClass.for(Acct.new("OtherAsset"), currency: "CNY")
    assert_equal "other", RealReturn::AssetClass.for(Acct.new("Vehicle"), currency: "USD")
  end
end
