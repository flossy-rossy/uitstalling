defmodule Uitstalling.Assets do
  @moduledoc """
  Stored visual assets: the indirection between deck JSON and actual bytes.

  Decks say `{"image": {"asset_id": "ast_..."}}`; this module owns where the
  bytes live and how they're served (`/a/:asset_id`). Storage is configured
  via `config :uitstalling, :asset_storage`:

      # dev/test (default)
      adapter: :local, dir: "priv/uploads"

      # prod — Tigris (Fly's S3): `fly storage create` injects the env vars
      adapter: :s3, bucket: ..., endpoint: ..., region: ...,
      access_key_id: ..., secret_access_key: ...

  Phase 1 covers uploads. Stock search and generation (the asset pipeline)
  plug in as new `origin` values writing through the same table and storage.
  """

  import Ecto.Query

  require Logger

  alias Uitstalling.Assets.Asset
  alias Uitstalling.Assets.Generator
  alias Uitstalling.Assets.ImageModels
  alias Uitstalling.Repo

  @max_bytes 5_000_000

  # Sniffed from magic bytes — the client's claimed content type is untrusted.
  @signatures [
    {<<0x89, "PNG\r\n", 0x1A, "\n">>, "image/png", "png"},
    {<<0xFF, 0xD8, 0xFF>>, "image/jpeg", "jpg"},
    {"GIF87a", "image/gif", "gif"},
    {"GIF89a", "image/gif", "gif"}
  ]

  @doc "Maximum accepted upload size in bytes."
  def max_bytes, do: @max_bytes

  @doc "Accepted upload extensions (for LiveView's `allow_upload` accept list)."
  def accepted_extensions, do: ~w(.png .jpg .jpeg .gif .webp)

  @doc """
  Ingest an uploaded file (a LiveView upload tmp path) as a new asset owned
  by `user_id`. Sniffs the real content type from magic bytes; rejects
  anything that isn't a supported image or is over #{@max_bytes} bytes.
  """
  def create_upload(user_id, tmp_path) do
    with {:ok, %{size: size}} when size <= @max_bytes <- file_stat(tmp_path),
         {:ok, content_type, ext} <- sniff(tmp_path) do
      insert_asset(user_id, "upload", {:file, tmp_path}, size, content_type, ext, [])
    else
      {:ok, %{size: _too_big}} -> {:error, :too_large}
      {:error, :unsupported_type} -> {:error, :unsupported_type}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Generate an image from a prompt (via the configured `Generator`) and store
  it as a new asset. The provider's bytes get the same sniff/size gate as an
  upload — a provider (or a compromised response) can't smuggle a non-image.

  `opts[:subject]` is what gets stored as the asset's prompt: the author's
  own words, so the image editor can offer them back for a regenerate. The
  full composed prompt (art direction etc.) is reproducible and not stored.
  """
  def create_generated(user_id, prompt, opts \\ []) do
    # An unknown/absent model falls back to the configured default — the
    # model id travels through a request row, so never trust it blindly.
    model =
      if ImageModels.valid?(opts[:model]),
        do: opts[:model],
        else: Application.get_env(:uitstalling, :image_model, ImageModels.default())

    with {:ok, %{bytes: bytes}} <- Generator.impl().generate(prompt, model: model),
         :ok <- check_size(bytes),
         {:ok, content_type, ext} <-
           match_signature(binary_part(bytes, 0, min(16, byte_size(bytes)))) do
      insert_asset(user_id, "gen", {:bytes, bytes}, byte_size(bytes), content_type, ext,
        prompt: opts[:subject] || prompt,
        provider: model
      )
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp check_size(bytes) when byte_size(bytes) <= @max_bytes, do: :ok
  defp check_size(_bytes), do: {:error, :too_large}

  defp insert_asset(user_id, origin, source, size, content_type, ext, extra) do
    id = generate_id()
    key = "#{id}.#{ext}"

    with :ok <- store(key, source, content_type) do
      do_insert_asset(id, key, user_id, origin, size, content_type, extra)
    end
  end

  defp do_insert_asset(id, key, user_id, origin, size, content_type, extra) do
    asset =
      Repo.insert!(%Asset{
        id: id,
        user_id: user_id,
        kind: "image",
        origin: origin,
        storage_key: key,
        content_type: content_type,
        byte_size: size,
        status: "ready",
        prompt: extra[:prompt],
        provider: extra[:provider]
      })

    {:ok, asset}
  end

  @doc "The asset with the given id, or nil."
  def get(id) when is_binary(id), do: Repo.get(Asset, id)
  def get(_id), do: nil

  @doc "Whether an asset exists and is servable."
  def ready?(id) do
    is_binary(id) and Repo.exists?(from(a in Asset, where: a.id == ^id and a.status == "ready"))
  end

  @doc """
  How to serve an asset: `{:file, path, content_type}` for local storage,
  `{:redirect, url}` for object storage.
  """
  def serve(%Asset{storage_key: key, content_type: content_type}) do
    case storage_config() do
      {:local, dir} -> {:file, Path.join(dir, key), content_type}
      {:s3, opts} -> {:redirect, public_url(opts, key)}
    end
  end

  @doc "Generate a fresh asset id."
  def generate_id do
    "ast_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end

  # ----- Storage --------------------------------------------------------------

  defp store(key, source, content_type) do
    case storage_config() do
      {:local, dir} ->
        File.mkdir_p!(dir)

        case source do
          {:file, path} -> File.cp!(path, Path.join(dir, key))
          {:bytes, bytes} -> File.write!(Path.join(dir, key), bytes)
        end

        :ok

      {:s3, opts} ->
        body =
          case source do
            {:file, path} -> File.read!(path)
            {:bytes, bytes} -> bytes
          end

        # A failed PUT must surface as an error the UI can show — a crash
        # here kills the LiveView, which remounts silently and looks like
        # "upload said done but nothing happened". HTTP.options adds
        # transient retries (idempotent: same key, same bytes).
        request =
          Uitstalling.HTTP.options(
            body: body,
            headers: [{"content-type", content_type}],
            aws_sigv4: [
              service: :s3,
              region: opts[:region] || "auto",
              access_key_id: opts[:access_key_id],
              secret_access_key: opts[:secret_access_key]
            ]
          )

        case Req.put(object_url(opts, key), request) do
          {:ok, %Req.Response{status: 200}} ->
            :ok

          {:ok, %Req.Response{status: status, body: resp_body}} ->
            Logger.warning("asset storage PUT #{status} for #{key}: #{inspect(resp_body)}")
            {:error, {:storage_failed, status}}

          {:error, reason} ->
            Logger.warning("asset storage PUT failed for #{key}: #{inspect(reason)}")
            {:error, {:storage_failed, reason}}
        end
    end
  end

  defp storage_config do
    config = Application.get_env(:uitstalling, :asset_storage, [])

    case config[:adapter] do
      :s3 -> {:s3, config}
      _ -> {:local, config[:dir] || "priv/uploads"}
    end
  end

  # Virtual-host style (bucket.host/key) for BOTH writes and public reads —
  # Tigris dropped path-style (host/bucket/key) for buckets created after
  # 2025-02-19, so path-style requests fail against any new bucket.
  # Public reads additionally require the bucket to be public
  # (`fly storage create --public`, or flip it in `fly storage dashboard`).
  # Presigned URLs can replace public reads if the bucket ever goes private.
  defp object_url(opts, key) do
    uri = URI.parse(opts[:endpoint] || "https://fly.storage.tigris.dev")
    "#{uri.scheme}://#{opts[:bucket]}.#{uri.host}/#{key}"
  end

  defp public_url(opts, key), do: object_url(opts, key)

  # ----- Upload validation -----------------------------------------------------

  defp file_stat(path) do
    case File.stat(path) do
      {:ok, stat} -> {:ok, stat}
      {:error, reason} -> {:error, reason}
    end
  end

  defp sniff(path) do
    case File.open(path, [:read, :binary], &IO.binread(&1, 16)) do
      {:ok, head} when is_binary(head) -> match_signature(head)
      _ -> {:error, :unsupported_type}
    end
  end

  defp match_signature(head) do
    # WEBP: "RIFF" <size:4> "WEBP"
    case head do
      <<"RIFF", _size::binary-size(4), "WEBP", _rest::binary>> ->
        {:ok, "image/webp", "webp"}

      _ ->
        Enum.find_value(@signatures, {:error, :unsupported_type}, fn {sig, type, ext} ->
          if String.starts_with?(head, sig), do: {:ok, type, ext}
        end)
    end
  end
end
