require "test_helper"

class ProjectionsControllerTest < ActionDispatch::IntegrationTest
  setup { sign_in users(:family_admin) }

  test "show renders successfully" do
    get projection_path
    assert_response :ok
  end

  test "show renders the traceable methodology breakdown panel" do
    get projection_path
    assert_response :ok
    assert_select "h2", text: "Methodology — every number is traceable"
    # the per-input provenance breakdown is present (anchored vs assumption tags)
    assert_match(/Assumption/, response.body)
    assert_match(/Anchored/, response.body)
  end

  test "show accepts horizon and contribution params" do
    get projection_path(years: 20, contribution: 50_000)
    assert_response :ok
  end

  test "show accepts custom allocation weights" do
    get projection_path(years: 20, w: { equity: 50, bonds: 30, gold: 20 })
    assert_response :ok
  end
end
