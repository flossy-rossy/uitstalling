defmodule UitstallingWeb.AuthController do
  @moduledoc """
  Passwordless WebAuthn auth (closed beta). Each ceremony is two legs:
  `*_begin` hands the browser a challenge (stashed in the session) plus options
  for `navigator.credentials.{create,get}`; `*_complete` verifies the result.

  Registration is gated by the email allowlist (`Accounts.allowed_email?/1`).
  Login is usernameless/discoverable, then re-checked against the allowlist.
  """
  use UitstallingWeb, :controller

  alias Uitstalling.Accounts
  alias Uitstalling.Accounts.{User, WebAuthn}
  alias UitstallingWeb.UserAuth

  @challenge_key "webauthn_challenge"
  @register_user_key "webauthn_register_user_id"

  # ----- Pages ------------------------------------------------------------

  def login_page(conn, _params) do
    render(conn, :login, layout: false, page_title: "Sign in")
  end

  def signup_page(conn, _params) do
    render(conn, :signup, layout: false, page_title: "Create your passkey")
  end

  def logout(conn, _params) do
    conn
    |> UserAuth.log_out_user()
    |> redirect(to: ~p"/")
  end

  # ----- Registration ceremony --------------------------------------------

  def register_begin(conn, params) do
    email = params["email"] || ""
    name = params["name"] || params["display_name"]

    case Accounts.register_user(email, name) do
      {:ok, user} ->
        {challenge, options} = WebAuthn.new_registration_challenge(user)

        conn
        |> put_session(@challenge_key, challenge)
        |> put_session(@register_user_key, user.id)
        |> json(%{publicKey: options})

      {:error, :not_allowed} ->
        error_json(conn, "That email isn't on the invite list.")
    end
  end

  def register_complete(conn, %{"credential" => credential} = params) do
    challenge = get_session(conn, @challenge_key)
    user = Accounts.get_user(get_session(conn, @register_user_key))

    with %Wax.Challenge{} <- challenge,
         %User{} <- user,
         {:ok, _cred} <-
           WebAuthn.verify_registration(user, credential, challenge, label: params["label"]) do
      conn
      |> clear_ceremony_session()
      |> UserAuth.log_in_user(user)
      |> json(%{ok: true, redirect: ~p"/"})
    else
      _ -> conn |> clear_ceremony_session() |> error_json("Registration failed")
    end
  end

  def register_complete(conn, _params), do: error_json(conn, "Registration failed")

  # ----- Authentication ceremony ------------------------------------------

  def login_begin(conn, _params) do
    {challenge, options} = WebAuthn.new_authentication_challenge()

    conn
    |> put_session(@challenge_key, challenge)
    |> json(%{publicKey: options})
  end

  def login_complete(conn, %{"credential" => credential}) do
    challenge = get_session(conn, @challenge_key)

    with %Wax.Challenge{} <- challenge,
         {:ok, %User{} = user} <- WebAuthn.verify_authentication(credential, challenge),
         true <- Accounts.can_author?(user) do
      conn
      |> clear_ceremony_session()
      |> UserAuth.log_in_user(user)
      |> json(%{ok: true, redirect: ~p"/"})
    else
      _ -> conn |> clear_ceremony_session() |> error_json("Authentication failed")
    end
  end

  def login_complete(conn, _params), do: error_json(conn, "Authentication failed")

  # ----- Helpers ----------------------------------------------------------

  defp clear_ceremony_session(conn) do
    conn
    |> delete_session(@challenge_key)
    |> delete_session(@register_user_key)
  end

  defp error_json(conn, message) do
    conn |> put_status(:unprocessable_entity) |> json(%{error: message})
  end
end
