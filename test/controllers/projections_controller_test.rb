require "test_helper"

class ProjectionsControllerTest < ActionDispatch::IntegrationTest
  setup { sign_in users(:family_admin) }

  test "show renders successfully" do
    get projection_path
    assert_response :ok
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
