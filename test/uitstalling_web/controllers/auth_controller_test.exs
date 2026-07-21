defmodule UitstallingWeb.AuthControllerTest do
  use UitstallingWeb.ConnCase, async: false

  import Uitstalling.Fixtures, only: [user_fixture: 0, credential_fixture: 1]

  alias Uitstalling.Accounts

  test "login page stores a same-app return_to for after the ceremony", %{conn: conn} do
    conn = get(conn, "/auth/login", return_to: "/deck/demo/remote")
    assert get_session(conn, "user_return_to") == "/deck/demo/remote"
  end

  test "login page refuses off-site return_to targets", %{conn: conn} do
    conn = get(conn, "/auth/login", return_to: "https://evil.example/")
    assert get_session(conn, "user_return_to") == nil

    conn = get(build_conn(), "/auth/login", return_to: "//evil.example/")
    assert get_session(conn, "user_return_to") == nil
  end

  test "register_begin hands an invited email a challenge", %{conn: conn} do
    Accounts.invite_user("friend@example.com", "Sam")

    conn = post(conn, "/auth/register/begin", %{"email" => "friend@example.com"})
    assert %{"publicKey" => %{"challenge" => challenge}} = json_response(conn, 200)
    assert is_binary(challenge)
  end

  test "register_begin refuses an account that already has a passkey", %{conn: conn} do
    user = user_fixture()
    credential_fixture(user)

    conn = post(conn, "/auth/register/begin", %{"email" => user.email})
    assert %{"error" => error} = json_response(conn, 422)
    assert error =~ "invite"
  end
end
