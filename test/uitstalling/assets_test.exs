defmodule Uitstalling.AssetsTest do
  use Uitstalling.DataCase, async: false

  alias Uitstalling.Assets

  @png <<0x89, "PNG\r\n", 0x1A, "\n", 0, 0, 0, 13, "IHDR">>
  @jpeg <<0xFF, 0xD8, 0xFF, 0xE0, 0, 16, "JFIF">>

  setup do
    user = Uitstalling.Fixtures.user_fixture()
    tmp = Path.join(System.tmp_dir!(), "asset-upload-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf("tmp/test-uploads") end)
    %{user: user, tmp: tmp}
  end

  test "ingests a PNG upload and serves it from local storage", %{user: user, tmp: tmp} do
    File.write!(tmp, @png)

    assert {:ok, asset} = Assets.create_upload(user.id, tmp)
    assert asset.id =~ ~r/^ast_[a-f0-9]{16}$/
    assert asset.content_type == "image/png"
    assert asset.origin == "upload"
    assert asset.status == "ready"
    assert Assets.ready?(asset.id)

    assert {:file, path, "image/png"} = Assets.serve(asset)
    assert File.read!(path) == @png
  end

  test "sniffs the real type — client claims don't matter", %{user: user, tmp: tmp} do
    File.write!(tmp, @jpeg)
    assert {:ok, asset} = Assets.create_upload(user.id, tmp)
    assert asset.content_type == "image/jpeg"
    assert asset.storage_key =~ ~r/\.jpg$/
  end

  test "rejects files that aren't images", %{user: user, tmp: tmp} do
    File.write!(tmp, "#!/bin/sh\nrm -rf /\n")
    assert {:error, :unsupported_type} = Assets.create_upload(user.id, tmp)
  end

  test "rejects oversized files", %{user: user, tmp: tmp} do
    File.write!(tmp, [@png, :binary.copy(<<0>>, Assets.max_bytes())])
    assert {:error, :too_large} = Assets.create_upload(user.id, tmp)
  end

  test "ready?/1 is false for unknown or malformed ids" do
    refute Assets.ready?("ast_0000000000000000")
    refute Assets.ready?(nil)
    refute Assets.ready?(123)
  end

  test "create_generated stores the generator's bytes with prompt metadata", %{user: user} do
    assert {:ok, asset} = Assets.create_generated(user.id, "a red panda astronaut")
    assert asset.origin == "gen"
    assert asset.prompt == "a red panda astronaut"
    assert asset.content_type == "image/png"
    assert Assets.ready?(asset.id)
  end

  test "generator failures pass through untouched", %{user: user} do
    assert {:error, :fake_generation_failed} = Assets.create_generated(user.id, "FAIL: nope")
  end
end
