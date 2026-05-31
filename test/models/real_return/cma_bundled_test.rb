require "test_helper"

class RealReturn::CmaBundledTest < ActiveSupport::TestCase
  setup { @cma = RealReturn::Cma.new } # default config/real_return/cma.yml

  REQUIRED = %w[equity_cn equity_us real_estate_cn real_estate_us gold govbond deposit crypto other].freeze

  test "all required asset classes load with a finite expected real return and positive sigma" do
    REQUIRED.each do |key|
      er = @cma.expected_real_return(key)
      assert er, "missing expected_real_return for #{key}"
      assert er.finite?, "#{key} expected real return not finite"
      assert er > -0.10 && er < 0.20, "#{key} expected real return #{er} out of a sane [-10%, 20%] band"
      assert @cma.sigma(key)&.positive?, "#{key} sigma must be positive"
    end
  end
end
