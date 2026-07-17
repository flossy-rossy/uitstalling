defmodule UitstallingWeb.UserAuth do
  @moduledoc """
  Session auth. A session is established by the WebAuthn ceremony
  (`Uitstalling.Accounts.WebAuthn`); these helpers manage the session cookie
  and the `:current_user` assign. Presenting is public, so a nil user is fine —
  authoring is gated by `Accounts.can_author?/1` at the call sites.

  Works as a plug (`fetch_current_user/2`) and an `on_mount` hook so the
  connection and LiveViews agree on who the user is.
  """
  import Plug.Conn

  alias Uitstalling.Accounts
  alias Uitstalling.Accounts.User

  def init(opts), do: opts
  def call(conn, _opts), do: fetch_current_user(conn, [])

  def fetch_current_user(conn, _opts) do
    user = Accounts.get_user(get_session(conn, "user_id"))
    assign(conn, :current_user, user)
  end

  def on_mount(:default, _params, session, socket) do
    user = Accounts.get_user(session["user_id"])
    {:cont, Phoenix.Component.assign(socket, :current_user, user)}
  end

  @doc "Logs `user` in: rotate the session (anti-fixation) and store the id."
  def log_in_user(conn, %User{} = user) do
    conn
    |> configure_session(renew: true)
    |> put_session("user_id", user.id)
    |> assign(:current_user, user)
  end

  @doc "Logs the current user out and drops the whole session."
  def log_out_user(conn) do
    conn
    |> clear_session()
    |> configure_session(drop: true)
  end
end
