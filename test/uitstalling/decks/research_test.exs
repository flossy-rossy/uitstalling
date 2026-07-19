defmodule Uitstalling.Decks.ResearchTest do
  use ExUnit.Case, async: true

  alias Uitstalling.Decks.Research

  defp docx_path(paragraphs) do
    xml =
      ~s(<?xml version="1.0"?><w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>) <>
        Enum.map_join(paragraphs, "", fn p -> "<w:p><w:r><w:t>#{p}</w:t></w:r></w:p>" end) <>
        "</w:body></w:document>"

    path = Path.join(System.tmp_dir!(), "research-#{System.unique_integer([:positive])}.docx")
    {:ok, _} = :zip.zip(String.to_charlist(path), [{~c"word/document.xml", xml}])
    on_exit(fn -> File.rm(path) end)
    path
  end

  test "extracts docx paragraphs as newline-separated text, unescaping XML entities" do
    path =
      docx_path(["WebAuthn shipped in Chrome 67.", "Costs: R100 &amp; falling &lt;fast&gt;."])

    assert {:ok, text} = Research.extract(path)
    assert text =~ "WebAuthn shipped in Chrome 67."
    assert text =~ "Costs: R100 & falling <fast>."
    assert text =~ "\n"
  end

  test "truncates very long documents with a marker" do
    path = docx_path([String.duplicate("facts and figures ", 3_000)])

    assert {:ok, text} = Research.extract(path)
    assert String.length(text) <= 30_020
    assert String.ends_with?(text, "[truncated]")
  end

  test "rejects non-document files by magic bytes, not filename" do
    path = Path.join(System.tmp_dir!(), "sneaky-#{System.unique_integer([:positive])}.pdf")
    File.write!(path, "#!/bin/sh\necho not a pdf\n")
    on_exit(fn -> File.rm(path) end)

    assert {:error, :unsupported_document} = Research.extract(path)
  end

  test "a docx with no readable text errors instead of grounding on nothing" do
    assert {:error, :no_text_found} = Research.extract(docx_path([]))
  end

  test "pdf extraction works when pdftotext is present, degrades clearly when not" do
    path = Path.join(System.tmp_dir!(), "research-#{System.unique_integer([:positive])}.pdf")

    # A minimal but real one-page PDF with a text object
    File.write!(path, minimal_pdf("Phishing costs are rising"))
    on_exit(fn -> File.rm(path) end)

    case System.find_executable("pdftotext") do
      nil ->
        assert {:error, :pdf_extraction_unavailable} = Research.extract(path)

      _exe ->
        assert {:ok, text} = Research.extract(path)
        assert text =~ "Phishing"
    end
  end

  defp minimal_pdf(text) do
    """
    %PDF-1.4
    1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj
    2 0 obj<</Type/Pages/Kids[3 0 R]/Count 1>>endobj
    3 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 612 792]/Contents 4 0 R/Resources<</Font<</F1 5 0 R>>>>>>endobj
    4 0 obj<</Length 60>>stream
    BT /F1 24 Tf 72 700 Td (#{text}) Tj ET
    endstream
    endobj
    5 0 obj<</Type/Font/Subtype/Type1/BaseFont/Helvetica>>endobj
    trailer<</Root 1 0 R>>
    """
  end
end
