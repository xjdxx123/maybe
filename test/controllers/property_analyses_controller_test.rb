require "test_helper"

class PropertyAnalysesControllerTest < ActionDispatch::IntegrationTest
  setup { sign_in users(:family_admin) }

  test "show renders with defaults" do
    get property_analysis_path
    assert_response :ok
  end

  test "show accepts property and financing params and renders the panels" do
    get property_analysis_path(price: 2_000_000, monthly_rent: 5_000, ltv: 50, mortgage_rate: 4.5,
                               holding_years: 20, region: "us")
    assert_response :ok
    assert_select "h1", /Property analysis/i
    assert_match(/Levered real equity/, response.body)
    assert_match(/Negative-equity paths/, response.body)
  end
end
