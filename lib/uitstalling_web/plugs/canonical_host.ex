defmodule UitstallingWeb.Plugs.CanonicalHost do
  @moduledoc """
  301s `www.<host>` to the bare host. One canonical origin matters three
  ways here: LiveView's `check_origin` only trusts the configured hosts (a
  www socket gets rejected and degrades to long-polling — the "stuck
  loading bar"), WebAuthn ceremonies pin the exact origin `https://<host>`
  (passkeys would fail on www), and search engines shouldn't see two copies
  of every deck.
  """

  @behaviour Plug

  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{host: "www." <> bare} = conn, opts) do
    # Redirect only OUR host's www — never any www (Phoenix test conns
    # default to www.example.com, and dev/preview hosts must pass through).
    if bare == Keyword.get(opts, :host) || bare == UitstallingWeb.Endpoint.host() do
      query = if conn.query_string == "", do: "", else: "?" <> conn.query_string

      conn
      |> put_resp_header("location", "https://#{bare}#{conn.request_path}#{query}")
      |> send_resp(301, "")
      |> halt()
    else
      conn
    end
  end

  def call(conn, _opts), do: conn
end
