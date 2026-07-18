defmodule UitstallingWeb.NewDeckLive do
  @moduledoc """
  The front door: theme, tone/audience, length, and a topic prompt. Submits a
  stub deck immediately (so /deck/:id exists), queues a "create" request for
  the pipeline, and navigates to the deck — which shows the generating overlay
  until the pipeline broadcasts completion.
  """

  use UitstallingWeb, :live_view

  alias Uitstalling.Accounts
  alias Uitstalling.Decks

  @minutes_options [5, 10, 15, 20, 30, 45]

  def mount(_params, _session, socket) do
    if Accounts.can_author?(socket.assigns.current_user) do
      {:ok, assign(socket, page_title: "New presentation", minutes_options: @minutes_options)}
    else
      {:ok, redirect(socket, to: ~p"/auth/login")}
    end
  end

  def render(assigns) do
    ~H"""
    <main class="min-h-dvh bg-zinc-950 text-zinc-100 px-8 sm:px-16 py-16">
      <div class="max-w-3xl mx-auto">
        <.link navigate={~p"/"} class="font-mono text-xs text-zinc-500 hover:text-amber-400">
          ← back
        </.link>

        <h1 class="mt-6 text-4xl sm:text-5xl font-bold">
          New <span class="text-amber-400">presentation</span>
        </h1>

        <form phx-submit="create" class="mt-12 space-y-10">
          <section>
            <p class="font-mono text-zinc-500 text-xs tracking-wider mb-3">THEME</p>
            <div class="grid sm:grid-cols-2 gap-4">
              <label class="cursor-pointer">
                <input type="radio" name="theme" value="noir" checked class="peer sr-only" />
                <div class="rounded-xl ring-1 ring-zinc-700 peer-checked:ring-2 peer-checked:ring-amber-400 bg-zinc-900 p-5 transition">
                  <div class="h-20 rounded-lg bg-zinc-950 ring-1 ring-zinc-800 p-4">
                    <div class="h-2 w-16 rounded bg-amber-400"></div>
                    <div class="mt-2 h-3 w-32 rounded bg-zinc-100"></div>
                    <div class="mt-2 h-2 w-24 rounded bg-zinc-600"></div>
                  </div>
                  <p class="mt-3 font-mono text-sm">noir</p>
                  <p class="font-mono text-xs text-zinc-500">black · amber</p>
                </div>
              </label>
              <label class="cursor-pointer">
                <input type="radio" name="theme" value="midnight" class="peer sr-only" />
                <div class="rounded-xl ring-1 ring-zinc-700 peer-checked:ring-2 peer-checked:ring-cyan-400 bg-zinc-900 p-5 transition">
                  <div class="h-20 rounded-lg bg-[#0a1128] ring-1 ring-slate-800 p-4">
                    <div class="h-2 w-16 rounded bg-cyan-400"></div>
                    <div class="mt-2 h-3 w-32 rounded bg-slate-100"></div>
                    <div class="mt-2 h-2 w-24 rounded bg-slate-600"></div>
                  </div>
                  <p class="mt-3 font-mono text-sm">midnight</p>
                  <p class="font-mono text-xs text-zinc-500">navy · cyan</p>
                </div>
              </label>
            </div>
          </section>

          <section>
            <p class="font-mono text-zinc-500 text-xs tracking-wider mb-3">TONE &amp; AUDIENCE</p>
            <input
              type="text"
              name="voice"
              placeholder="e.g. technical conference crowd — punchy, confident, no fluff"
              class="w-full bg-zinc-900 text-zinc-100 rounded-lg ring-1 ring-zinc-700 focus:ring-amber-500 border-0 p-4 font-sans"
            />
          </section>

          <section>
            <p class="font-mono text-zinc-500 text-xs tracking-wider mb-3">TALK LENGTH</p>
            <select
              name="minutes"
              class="w-full sm:w-64 bg-zinc-900 text-zinc-100 rounded-lg ring-1 ring-zinc-700 focus:ring-amber-500 border-0 p-4 font-mono"
            >
              {Phoenix.HTML.Form.options_for_select(
                Enum.map(@minutes_options, &{"#{&1} minutes · ~#{target_slides(&1)} slides", &1}),
                10
              )}
            </select>
          </section>

          <section>
            <p class="font-mono text-zinc-500 text-xs tracking-wider mb-3">
              WHAT'S THE TALK ABOUT?
            </p>
            <textarea
              name="prompt"
              rows="6"
              required
              placeholder="The topic, the main points you want to land, anything the audience must walk away knowing…"
              class="w-full bg-zinc-900 text-zinc-100 rounded-lg ring-1 ring-zinc-700 focus:ring-amber-500 border-0 p-4 font-sans"
            ></textarea>
          </section>

          <button
            type="submit"
            class="w-full py-4 rounded-lg bg-amber-500 hover:bg-amber-400 text-zinc-950 font-bold text-lg shadow-lg shadow-amber-500/20 transition"
          >
            Generate my deck
          </button>
        </form>
      </div>
    </main>
    """
  end

  def handle_event("create", params, socket) do
    prompt = String.trim(params["prompt"] || "")

    cond do
      not Accounts.can_author?(socket.assigns.current_user) ->
        {:noreply, redirect(socket, to: ~p"/auth/login")}

      prompt == "" ->
        {:noreply, socket}

      true ->
        create_deck(socket, params, prompt)
    end
  end

  defp create_deck(socket, params, prompt) do
    theme = if params["theme"] == "midnight", do: "midnight", else: "noir"
    accent = if theme == "midnight", do: "cyan", else: "amber"
    minutes = parse_minutes(params["minutes"])

    voice =
      case String.trim(params["voice"] || "") do
        "" -> "punchy, confident, plain language"
        voice -> voice
      end

    deck_id = Decks.generate_id()
    Decks.create_deck!(socket.assigns.current_user.id, deck_id, stub_deck(theme, accent, voice))

    Decks.queue_request(%{
      "type" => "create",
      "deck_id" => deck_id,
      "theme" => theme,
      "accent" => accent,
      "voice" => voice,
      "minutes" => minutes,
      "target_slides" => target_slides(minutes),
      "prompt" => prompt
    })

    Decks.DeckWorker.kick(deck_id)

    {:noreply, push_navigate(socket, to: ~p"/deck/#{deck_id}")}
  end

  # ~0.75 slides per talk minute is a comfortable pace; floor of 4.
  defp target_slides(minutes), do: max(4, round(minutes * 0.75))

  defp parse_minutes(value) do
    case Integer.parse(to_string(value)) do
      {minutes, ""} when minutes in @minutes_options -> minutes
      _ -> 10
    end
  end

  # Valid placeholder deck so /deck/:id renders instantly; the pipeline
  # replaces it wholesale when generation lands.
  defp stub_deck(theme, accent, voice) do
    %{
      "title" => "New presentation",
      "theme" => theme,
      "accent" => accent,
      "voice" => voice,
      "slides" => [
        %{
          "id" => "s0",
          "layout" => "statement",
          "kicker" => "PRESENTATION_ME",
          "body" =>
            "==Generating your presentation…==\n\nThis page updates itself the moment it's ready."
        }
      ]
    }
  end
end
