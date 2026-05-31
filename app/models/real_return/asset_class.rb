module RealReturn
  # Maps an Account to a CMA asset-class key. Equities and real estate are
  # region-suffixed by the family's currency (CNY -> _cn, else _us).
  module AssetClass
    module_function

    def for(account, currency:)
      region = Region.real_estate(currency).downcase # "cn" / "us"
      case account.accountable_type
      when "Property"   then "real_estate_#{region}"
      when "Investment" then "equity_#{region}"
      when "Crypto"     then "crypto"
      when "Depository" then "deposit"
      else                   "other" # OtherAsset, Vehicle, etc.
      end
    end
  end
end
