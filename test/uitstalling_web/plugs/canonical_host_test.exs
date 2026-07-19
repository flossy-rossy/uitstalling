defmodule UitstallingWeb.Plugs.CanonicalHostTest do
  use ExUnit.Case, async: true

  import Plug.Test
  import Plug.Conn

  alias UitstallingWeb.Plugs.CanonicalHost

  @opts [host: "uitstalling.co.za"]

  test "www of the canonical host 301s to it, keeping path and query" do
    conn =
      conn(:get, "/deck/abc123?remote=1")
      |> Map.put(:host, "www.uitstalling.co.za")
      |> CanonicalHost.call(@opts)

    assert conn.status == 301
    assert conn.halted

    assert get_resp_header(conn, "location") == [
             "https://uitstalling.co.za/deck/abc123?remote=1"
           ]
  end

  test "the bare host and non-www hosts pass through untouched" do
    for host <- ["uitstalling.co.za", "uitstalling.fly.dev", "localhost"] do
      conn = conn(:get, "/") |> Map.put(:host, host) |> CanonicalHost.call(@opts)
      refute conn.halted
      assert conn.status == nil
    end
  end

  test "www of a DIFFERENT host is not our redirect to give (test conns, previews)" do
    conn =
      conn(:get, "/")
      |> Map.put(:host, "www.example.com")
      |> CanonicalHost.call(@opts)

    refute conn.halted
    assert conn.status == nil
  end
end
