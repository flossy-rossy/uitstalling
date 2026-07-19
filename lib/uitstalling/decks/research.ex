defmodule Uitstalling.Decks.Research do
  @moduledoc """
  Extract plain text from an uploaded research document (.pdf / .docx) so
  the create prompt can ground the deck in it. Extraction is server-side and
  provider-agnostic on purpose — native document input only exists on some
  providers, and DOCX on none. The file itself is never stored: text out,
  bytes discarded.

  Type is sniffed from magic bytes, never from the filename. PDFs go through
  `pdftotext` (poppler-utils — in the prod image; `brew install poppler` for
  dev). DOCX is a zip of XML, unpacked in-process.
  """

  # ~7-8k tokens of grounding — plenty for a deck, bounded for the prompt.
  @max_chars 30_000

  @doc "Extract text: `{:ok, text}` (UTF-8, truncated to #{@max_chars} chars) or `{:error, reason}`."
  def extract(path) do
    case File.read(path) do
      {:ok, <<"%PDF", _rest::binary>>} -> pdf_text(path)
      {:ok, <<"PK", 0x03, 0x04, _rest::binary>>} -> docx_text(path)
      {:ok, _other} -> {:error, :unsupported_document}
      {:error, reason} -> {:error, reason}
    end
    |> clean()
  end

  defp pdf_text(path) do
    case System.find_executable("pdftotext") do
      nil ->
        {:error, :pdf_extraction_unavailable}

      exe ->
        case System.cmd(exe, ["-q", path, "-"], stderr_to_stdout: true) do
          {text, 0} -> {:ok, text}
          {output, _status} -> {:error, {:pdf_extraction_failed, String.slice(output, 0, 200)}}
        end
    end
  end

  defp docx_text(path) do
    with {:ok, [{_name, xml}]} <-
           :zip.unzip(String.to_charlist(path), [
             :memory,
             {:file_list, [~c"word/document.xml"]}
           ]) do
      text =
        xml
        |> String.replace(~r{</w:p>}, "\n")
        |> String.replace(~r{<w:tab[^>]*/>}, "\t")
        |> String.replace(~r{<[^>]+>}, "")
        |> unescape_xml()

      {:ok, text}
    else
      _ -> {:error, :docx_extraction_failed}
    end
  end

  defp unescape_xml(text) do
    text
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace("&apos;", "'")
    |> String.replace("&amp;", "&")
  end

  # The text ends up inside a JSON payload column and a prompt: it must be
  # valid UTF-8 and bounded.
  defp clean({:ok, text}) do
    text =
      text
      |> scrub_utf8()
      |> String.replace(~r/\n{3,}/, "\n\n")
      |> String.trim()

    cond do
      text == "" ->
        {:error, :no_text_found}

      String.length(text) > @max_chars ->
        {:ok, String.slice(text, 0, @max_chars) <> "\n[truncated]"}

      true ->
        {:ok, text}
    end
  end

  defp clean(error), do: error

  defp scrub_utf8(text) do
    if String.valid?(text) do
      text
    else
      text |> String.chunk(:valid) |> Enum.filter(&String.valid?/1) |> Enum.join()
    end
  end
end
