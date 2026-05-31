require "test_helper"

class RealReturnsControllerTest < ActionDispatch::IntegrationTest
  setup { sign_in users(:family_admin) }

  test "show renders successfully" do
    get real_return_path
    assert_response :ok
  end
end
