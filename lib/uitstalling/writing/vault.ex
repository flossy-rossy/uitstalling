defmodule Uitstalling.Writing.Vault do
  @moduledoc """
  Envelope encryption for the writing feature (docs/writing.md).

  Each project owns a random 32-byte DEK; content (doc bodies, titles, event
  payloads) is AES-256-GCM under that DEK. The DEK is stored wrapped by a
  master KEK read from `:writing_master_keys` — a ring of `id:base64` pairs
  where the FIRST entry wraps new material and every entry can unwrap, so
  rotation is: add a new first key, re-wrap the DEKs
  (`Uitstalling.Writing.rotate_project_keys!/0`), drop the old entry.
  Content is never re-encrypted by a rotation.

  Every ciphertext binds the owning row's id as AAD — a blob lifted from one
  row will not decrypt against another.
  """

  @iv_bytes 12
  @tag_bytes 16
  @dek_bytes 32

  @doc "A fresh random project DEK."
  def generate_dek, do: :crypto.strong_rand_bytes(@dek_bytes)

  @doc "Wrap a DEK under the active KEK. Returns `{kek_id, wrapped}`."
  def wrap_dek(dek, aad) when byte_size(dek) == @dek_bytes do
    {kek_id, kek} = active_key()
    {kek_id, seal(kek, dek, aad)}
  end

  @doc """
  Unwrap a stored DEK with the ring entry that wrapped it. Raises on an
  unknown kek_id (the ring lost a key that still wraps live data) or a
  tampered blob — both are configuration emergencies, not user errors.
  """
  def unwrap_dek(kek_id, wrapped, aad) do
    case List.keyfind(key_ring(), kek_id, 0) do
      {^kek_id, kek} ->
        case open(kek, wrapped, aad) do
          {:ok, dek} ->
            dek

          :error ->
            raise "writing vault: DEK for #{inspect(aad)} failed to unwrap — wrong KEK material?"
        end

      nil ->
        raise "writing vault: no KEK #{inspect(kek_id)} in the ring — " <>
                "restore it to WRITING_MASTER_KEYS before touching this project"
    end
  end

  @doc "Encrypt `plaintext` under a DEK, bound to `aad`."
  def encrypt(dek, plaintext, aad) when is_binary(plaintext), do: seal(dek, plaintext, aad)

  @doc "Decrypt a blob produced by `encrypt/3`. `{:ok, plaintext}` or `:error`."
  def decrypt(dek, blob, aad), do: open(dek, blob, aad)

  @doc "The id of the KEK new material is wrapped with."
  def active_kek_id do
    {kek_id, _kek} = active_key()
    kek_id
  end

  # ----- AES-256-GCM plumbing ---------------------------------------------------

  defp seal(key, plaintext, aad) do
    iv = :crypto.strong_rand_bytes(@iv_bytes)
    {ct, tag} = :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, plaintext, aad, true)
    iv <> tag <> ct
  end

  defp open(key, <<iv::binary-size(@iv_bytes), tag::binary-size(@tag_bytes), ct::binary>>, aad) do
    case :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, ct, aad, tag, false) do
      plaintext when is_binary(plaintext) -> {:ok, plaintext}
      :error -> :error
    end
  end

  defp open(_key, _blob, _aad), do: :error

  # ----- Key ring -----------------------------------------------------------------

  defp active_key do
    case key_ring() do
      [first | _] -> first
      [] -> raise_missing()
    end
  end

  defp key_ring do
    case Application.fetch_env(:uitstalling, :writing_master_keys) do
      {:ok, spec} when is_binary(spec) and spec != "" -> parse_ring(spec)
      _ -> raise_missing()
    end
  end

  defp parse_ring(spec) do
    spec
    |> String.split(",", trim: true)
    |> Enum.map(fn entry ->
      case String.split(String.trim(entry), ":", parts: 2) do
        [id, b64] when id != "" ->
          case Base.decode64(b64) do
            {:ok, key} when byte_size(key) == @dek_bytes ->
              {id, key}

            _ ->
              raise "writing vault: KEK #{inspect(id)} must be base64 of exactly 32 bytes"
          end

        _ ->
          raise "writing vault: WRITING_MASTER_KEYS entries look like id:base64key"
      end
    end)
  end

  defp raise_missing do
    raise """
    writing vault: no master keys configured.
    Set WRITING_MASTER_KEYS (e.g. "k1:#{Base.encode64(:crypto.strong_rand_bytes(32))}")
    — and back that value up somewhere safe: losing every KEK loses the writing.
    """
  end
end
