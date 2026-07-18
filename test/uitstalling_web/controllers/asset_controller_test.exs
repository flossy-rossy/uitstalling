defmodule UitstallingWeb.AssetControllerTest do
  use UitstallingWeb.ConnCase, async: false

  alias Uitstalling.Assets

  @png <<0x89, "PNG\r\n", 0x1A, "\n", 0, 0, 0, 13, "IHDR">>

  setup do
    user = Uitstalling.Fixtures.user_fixture()
    tmp = Path.join(System.tmp_dir!(), "asset-serve-#{System.unique_integer([:positive])}")
    File.write!(tmp, @png)
    {:ok, asset} = Assets.create_upload(user.id, tmp)
    on_exit(fn -> File.rm_rf("tmp/test-uploads") end)
    %{asset: asset}
  end

  test "serves a ready asset with its sniffed content type", %{conn: conn, asset: asset} do
    conn = get(conn, "/a/#{asset.id}")

    assert conn.status == 200
    assert [content_type] = get_resp_header(conn, "content-type")
    assert content_type =~ "image/png"
    assert [cache] = get_resp_header(conn, "cache-control")
    assert cache =~ "immutable"
  end

  test "404s for unknown ids", %{conn: conn} do
    assert conn |> get("/a/ast_ffffffffffffffff") |> response(404)
    assert conn |> get("/a/not-even-an-id") |> response(404)
  end
end
