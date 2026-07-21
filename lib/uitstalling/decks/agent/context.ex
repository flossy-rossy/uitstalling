defmodule Uitstalling.Decks.Agent.Context do
  @moduledoc """
  The context engine: everything between app state and model text.

  Every prompt the app sends a model — deck creation, slide edits, scoped
  ops, image generation — is assembled here, from one place, so context
  (theme, voice, the deck's arc, research grounding, retry feedback) evolves
  without touching the wire clients. The agent modules
  (`Agent.Claude`, `Agent.OpenAI`) own ONLY request shape: how these strings
  are packed into a provider's API call.

  Inbound handling lives here too: `extract_json/1` turns a model reply into
  the JSON object the pipeline validates.
  """

  alias Uitstalling.Decks

  # ----- Edit: whole-slide replacement -----------------------------------------

  def edit_system_prompt do
    """
    You are a slide-deck edit agent for a presentation builder. You receive a
    deck (JSON), one edit request targeting a single slide, and you return the
    COMPLETE replacement JSON object for that one slide.

    Rules:
    - Respond with ONLY the slide JSON object. No prose, no markdown fences.
    - Stay strictly within the design system described below. Unknown keys,
      unknown layouts, and off-palette values are rejected by a validator.
    - Preserve the slide's "id" and any fields the request doesn't ask you to
      change. When the request scopes the edit to one named part ("block"),
      every other field must be returned byte-for-byte unchanged.
    - Match the deck's writing voice.

    #{Decks.schema_prompt()}
    """
  end

  # The deck is stable across retries and consecutive edits — it lives in its
  # own system block so the API can cache it separately from the request.
  def edit_context_prompt(deck) do
    voice =
      case deck["voice"] do
        v when is_binary(v) and v != "" ->
          v

        _ ->
          "not set — infer the voice from the existing slides' text and match it exactly"
      end

    """
    Deck voice: #{voice}

    Full deck for context:
    #{Jason.encode!(deck)}
    """
  end

  def edit_user_prompt(deck, request, retry) do
    """
    Edit request for the slide with id=#{request["slide_id"]} (layout=#{request["layout"]}):
    "#{request["prompt"]}"
    #{slide_context_line(deck, request["slide_id"])}
    The request applies to the whole slide.

    Return the complete replacement JSON object for this one slide.
    #{retry_block(retry)}
    """
  end

  # Anchor the edit in the deck's arc — the full deck is in the context
  # block, but small models miss it; say where this slide sits explicitly.
  defp slide_context_line(deck, slide_id) do
    slide = Enum.find(List.wrap(deck["slides"]), &(is_map(&1) and &1["id"] == slide_id))

    case slide do
      %{"kicker" => kicker} when is_binary(kicker) and kicker != "" ->
        "This slide sits in the section \"#{kicker}\" — keep the edit coherent with that " <>
          "section and the deck's overall arc.\n"

      _ ->
        ""
    end
  end

  # ----- Ops: scoped edits emit operations, never slides --------------------------

  def ops_system_prompt do
    """
    You are a slide-deck edit agent for a presentation builder. You receive a
    deck (JSON), and one edit request scoped to a single named part of one
    slide. You respond with the OPERATIONS that perform the change — never
    with the slide itself.

    Respond with ONLY this JSON object. No prose, no markdown fences:
    {"ops": [ ... ]}

    Operations (parts are addressed by their app-assigned "id"):
    - {"op": "set_field", "field": "<name>", "value": <value>}
      sets a field on the slide itself
    - {"op": "set_field", "part": "<part id>", "field": "<name>", "value": <value>}
      sets a field on one list part
    - {"op": "delete_field", "field": "<name>"} / with "part" — removes a field
    - {"op": "replace_part", "part": "<part id>", "value": {<full replacement part>}}
    - {"op": "insert_part", "list": "points|steps|items", "after": "<part id>"|"start"|"end", "part": {<the new part>}}
    - {"op": "remove_part", "part": "<part id>"}
    - {"op": "move_part", "part": "<part id>", "after": "<part id>"|"start"|"end"}

    Rules:
    - Emit ONLY ops that change the requested target — nothing else on the
      slide may be touched, and a validator rejects out-of-scope ops.
    - Prefer the smallest ops that do the job (set one field over replacing
      a whole part).
    - Never set "id", "layout", or "image" — they are app-managed.
    - Values must stay within the design system below.
    - Match the deck's writing voice.

    #{Decks.schema_prompt()}
    """
  end

  def ops_user_prompt(deck, request, retry) do
    """
    Edit request for the slide with id=#{request["slide_id"]} (layout=#{request["layout"]}):
    "#{request["prompt"]}"
    #{slide_context_line(deck, request["slide_id"])}
    #{target_description(request["target"])}

    Return {"ops": [...]} performing exactly this change.
    #{retry_block(retry)}
    """
  end

  defp target_description(%{"kind" => "field", "field" => field}) do
    "Your ops may change ONLY the \"#{field}\" field of the slide itself (no \"part\" key)."
  end

  defp target_description(%{"kind" => "part", "part" => part}) do
    "Your ops may change ONLY the part with id \"#{part}\" (set/delete its fields, or replace_part it)."
  end

  defp target_description(%{"kind" => "part_field", "part" => part, "field" => field}) do
    "Your ops may change ONLY the \"#{field}\" field of the part with id \"#{part}\"."
  end

  defp target_description(_target), do: "Change only what the request asks for."

  # ----- Create: a whole deck ------------------------------------------------------

  def create_system_prompt do
    """
    You are a presentation author for a slide-deck builder. You receive a talk
    description plus theme/voice/length choices, and you return a COMPLETE deck
    as one JSON object.

    Rules:
    - Respond with ONLY the deck JSON object. No prose, no markdown fences.
    - Stay strictly within the design system described below — a validator
      rejects anything outside it.
    - Give every slide an "id" (short, unique, e.g. "s0", "s1", ...).
    - Open with a "title" slide; kickers ("§ 1 · TOPIC" style) keep the
      audience oriented; add speaker "notes" where delivery guidance helps.
    - Hit the requested slide count within ±2 slides.

    Form follows the material — decide the deck's character FIRST:
    - Before writing slides, decide what KIND of presentation this subject
      and audience demand. A technical deep-dive earns flows, tables, and
      code; a clinical, consumer, or persuasive talk earns image-led slides,
      bold statements, and point grids with almost no bullets; a data story
      earns tables with tinted cells and stark single-number statement
      slides. Commit to that character and let it shape every slide.
    - NEVER reuse a stock conference-deck skeleton. Two decks on different
      subjects must not share a structure; do not tour the layout catalog
      one-of-each. It is better to use three layouts brilliantly than seven
      dutifully.
    - Vary the rhythm: cluster short punchy slides, then let one breathe.
      Consecutive slides should rarely share a layout unless the repetition
      is the point.

    Images — request them where a visual carries the idea:
    - On the OPENING title slide, always include
      "image_request": {"subject": "<what to depict>"} — one striking,
      concrete visual that captures the talk (a scene, an object, a metaphor
      made literal; never an abstract collage). The app generates it; you
      only describe it.
    - You may add "image_request" to UP TO TWO more slides — spend them on
      the moments where showing beats telling (the product, the place, the
      before/after). For non-technical audiences, lean visual; for technical
      audiences, prefer a flow or table over a picture.
    - Subjects must be concrete and specific to THIS slide's idea, never
      decorative filler. NEVER request people, faces, hands, or crowds, and
      never a photorealistic scene — the generator renders those poorly.
      Depict the object, the place, or the metaphor instead (the empty
      waiting-room chair, not the patient).

    Quality bar — what separates a good deck from filler:
    - Slides are not essays: short, punchy lines; at most ~5 bullets on a
      slide; one idea per slide. The narration belongs in "notes".
    - Be concrete and specific: real numbers, named examples, sharp claims —
      never generic filler like "in today's fast-paced world".
    - Use ==accent== marks on THE key phrase of a slide (sparingly — one or
      two per slide), **strong** for emphasis, `code` for identifiers.
    - Make the deck tell a story: a hook up front, rising stakes, a payoff.
      Section kickers should trace that arc.

    #{Decks.schema_prompt()}
    """
  end

  def create_user_prompt(request, retry) do
    """
    Create a presentation.

    Theme: #{request["theme"]} (set "theme" and use accent "#{request["accent"]}")
    Voice / audience: #{request["voice"]}
    Talk length: #{request["minutes"]} minutes — aim for #{request["target_slides"]} slides (±2).

    What the talk is about, and the main points to cover:
    #{request["prompt"]}
    #{research_block(request)}
    Return the complete deck JSON object.
    #{retry_block(retry)}
    """
  end

  # Author-supplied grounding material, extracted server-side from their
  # uploaded document. This is the difference between a deck of concrete
  # claims and a deck of generic filler — the model is told to mine it.
  defp research_block(request) do
    case request["research"] do
      text when is_binary(text) and text != "" ->
        """

        The author uploaded research material ("#{request["research_filename"] || "document"}").
        Ground the deck in it: pull the concrete facts, numbers, names, and quotes from this
        material instead of inventing generic content. Where a specific source or figure
        carries a slide, a "footnote" is a good place to attribute it.

        <research>
        #{text}
        </research>
        """

      _ ->
        ""
    end
  end

  defp retry_block(nil), do: ""

  defp retry_block(%{errors: errors} = retry) do
    previous =
      case retry[:previous] do
        %{} = map ->
          """
          Your previous attempt was:
          #{Jason.encode!(map)}
          """

        _ ->
          ""
      end

    """

    #{previous}It was rejected by the validator with these errors:
    #{Enum.map_join(errors, "\n", &("- " <> &1))}
    Fix ONLY what the errors require and return the corrected JSON.
    """
  end

  # ----- Images ---------------------------------------------------------------

  # Art direction per deck theme — images must sit ON the slide, not fight it.
  @theme_direction %{
    "noir" => "near-black background with warm amber accent lighting",
    "midnight" => "deep navy background with cyan accent lighting"
  }

  @doc """
  Compose the full generation prompt for an image on a slide: the subject
  first, then the deck's art direction (theme, title, voice) and the slide's
  own context (section kicker, heading) so the image belongs to THIS deck
  and THIS moment in it — never a context-free stock-alike.
  """
  def image_prompt(raw, slide, subject) do
    direction = @theme_direction[raw["theme"]] || @theme_direction["noir"]

    slide_context =
      [
        is_binary(slide["kicker"]) && slide["kicker"] != "" && "section \"#{slide["kicker"]}\"",
        is_binary(slide["heading"]) && slide["heading"] != "" &&
          "slide heading \"#{slide["heading"]}\""
      ]
      |> Enum.filter(&is_binary/1)
      |> case do
        [] -> ""
        parts -> "It illustrates the #{Enum.join(parts, ", ")}.\n"
      end

    voice =
      case raw["voice"] do
        v when is_binary(v) and v != "" -> "Tone: #{v}.\n"
        _ -> ""
      end

    """
    #{subject}

    A 16:9 visual for one slide of a presentation titled "#{raw["title"]}".
    #{slide_context}#{voice}Style: #{direction}; modern, minimal, high contrast; \
    stylized and graphic — bold editorial illustration, never photorealism. \
    NEVER depict people, faces, or hands; render human subjects through \
    objects, environments, or visual metaphor instead. \
    No embedded text or captions unless the subject explicitly asks for them.
    """
  end

  # ----- Inbound: model reply → JSON object -------------------------------------

  # The model is asked for bare JSON, but be lenient: try the whole reply,
  # then each fenced block, then the outermost brace span. Among candidates
  # that decode to an object, the LARGEST wins — a reply that narrates with
  # a small example object before the real payload must not have its example
  # parsed as the answer.
  def extract_json(text) do
    text = String.trim(text)

    candidates = [text] ++ fenced_blocks(text) ++ brace_span(text)

    decoded = Enum.map(candidates, &{&1, Jason.decode(&1)})

    objects =
      for {source, {:ok, %{} = object}} <- decoded, do: {byte_size(source), object}

    cond do
      objects != [] ->
        {_size, object} = Enum.max_by(objects, &elem(&1, 0))
        {:ok, object}

      Enum.any?(decoded, &match?({_, {:ok, _}}, &1)) ->
        {:error, :not_an_object}

      true ->
        {:error, {:invalid_json, first_decode_error(decoded)}}
    end
  end

  defp first_decode_error(decoded) do
    Enum.find_value(decoded, "no JSON found", fn
      {_source, {:error, err}} -> Exception.message(err)
      _ -> nil
    end)
  end

  defp fenced_blocks(text) do
    ~r/```(?:json)?\s*(.*?)```/s
    |> Regex.scan(text, capture: :all_but_first)
    |> Enum.map(fn [inner] -> String.trim(inner) end)
  end

  defp brace_span(text) do
    with first when first != nil <- first_index(text, "{"),
         last when last != nil and last > first <- last_index(text, "}") do
      [binary_part(text, first, last - first + 1)]
    else
      _ -> []
    end
  end

  defp first_index(text, char) do
    case :binary.match(text, char) do
      {pos, _} -> pos
      :nomatch -> nil
    end
  end

  defp last_index(text, char) do
    case :binary.matches(text, char) do
      [] -> nil
      matches -> matches |> List.last() |> elem(0)
    end
  end
end
