defmodule Uitstalling.Writing.VaultTest do
  use ExUnit.Case, async: true

  alias Uitstalling.Writing.Vault

  test "encrypt/decrypt roundtrips under a DEK" do
    dek = Vault.generate_dek()
    blob = Vault.encrypt(dek, "the moor was silent", "doc1")

    assert {:ok, "the moor was silent"} = Vault.decrypt(dek, blob, "doc1")
    refute blob =~ "moor"
  end

  test "two encryptions of the same plaintext differ (fresh IV)" do
    dek = Vault.generate_dek()

    assert Vault.encrypt(dek, "same words", "doc1") != Vault.encrypt(dek, "same words", "doc1")
  end

  test "a blob bound to one row does not decrypt against another" do
    dek = Vault.generate_dek()
    blob = Vault.encrypt(dek, "chapter one", "doc1")

    assert :error = Vault.decrypt(dek, blob, "doc2")
  end

  test "the wrong DEK fails, as does a truncated blob" do
    dek = Vault.generate_dek()
    blob = Vault.encrypt(dek, "text", "doc1")

    assert :error = Vault.decrypt(Vault.generate_dek(), blob, "doc1")
    assert :error = Vault.decrypt(dek, binary_part(blob, 0, 10), "doc1")
  end

  test "wrap/unwrap roundtrips with the active KEK" do
    dek = Vault.generate_dek()
    {kek_id, wrapped} = Vault.wrap_dek(dek, "proj1")

    assert kek_id == Vault.active_kek_id()
    assert Vault.unwrap_dek(kek_id, wrapped, "proj1") == dek
  end

  test "test ring: t2 is active, retired t1 still unwraps" do
    # config/test.exs pins "t2:...,t1:..." — first entry wraps new material,
    # every entry can unwrap.
    assert Vault.active_kek_id() == "t2"

    t1 = Base.decode64!("s9+JKJWMM6j9tYCJ87lN0YoyYg8atGxxJSNg0SXK6wk=")
    dek = Vault.generate_dek()
    iv = :crypto.strong_rand_bytes(12)
    {ct, tag} = :crypto.crypto_one_time_aead(:aes_256_gcm, t1, iv, dek, "proj1", true)

    assert Vault.unwrap_dek("t1", iv <> tag <> ct, "proj1") == dek
  end

  test "an unknown kek_id raises loudly" do
    dek = Vault.generate_dek()
    {_kek_id, wrapped} = Vault.wrap_dek(dek, "proj1")

    assert_raise RuntimeError, ~r/no KEK "gone" in the ring/, fn ->
      Vault.unwrap_dek("gone", wrapped, "proj1")
    end
  end
end
