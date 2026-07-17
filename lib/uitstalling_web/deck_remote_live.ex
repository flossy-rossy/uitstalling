defmodule UitstallingWeb.DeckRemoteLive do
  @moduledoc """
  Phone remote + presenter view for a deck: prev/next buttons, position,
  and the current slide's speaker notes. Drives every connected viewer of
  the same deck over PubSub.
  """

  use UitstallingWeb, :live_view

  alias Uitstalling.Decks
  alias Uitstalling.Decks.Slide

  def mount(%{"id" => deck_id}, _session, socket) do
    if Decks.exists?(deck_id) do
      deck = Decks.deck!(deck_id)
      topic = "deck:#{deck_id}"

      if connected?(socket) do
        Phoenix.PubSub.subscribe(Uitstalling.PubSub, topic)
      end

      {:ok,
       assign(socket,
         deck_id: deck_id,
         topic: topic,
         page_title: "Remote · #{deck.title}",
         deck: deck,
         index: 0
       )}
    else
      {:ok, socket |> put_flash(:error, "No such presentation") |> redirect(to: ~p"/")}
    end
  end

  def render(assigns) do
    assigns = assign(assigns, :slide, Enum.at(assigns.deck.slides, assigns.index))

    ~H"""
    <main class="min-h-dvh bg-zinc-950 text-zinc-100 flex flex-col p-6">
      <header>
        <p class="font-mono text-amber-400 text-xs tracking-wider">REMOTE · {@deck.title}</p>
        <p class="mt-2 font-mono text-zinc-500 text-sm">{@index + 1} / {length(@deck.slides)}</p>
      </header>

      <section class="flex-1 mt-8">
        <p class="font-mono text-zinc-600 text-xs mb-2 uppercase">{@slide.layout}</p>
        <p class="text-2xl font-semibold leading-snug">{slide_label(@slide)}</p>

        <div :if={@slide.notes} class="mt-6 p-4 bg-zinc-900 rounded-lg ring-1 ring-zinc-800">
          <p class="font-mono text-xs text-amber-400 mb-2">NOTES</p>
          <p class="text-zinc-300 leading-relaxed">{@slide.notes}</p>
        </div>
      </section>

      <section class="grid grid-cols-2 gap-4 pb-4">
        <button
          phx-click="step"
          phx-value-dir="-1"
          class="py-12 rounded-xl bg-zinc-800 text-3xl font-bold active:bg-zinc-700"
        >
          ←
        </button>
        <button
          phx-click="step"
          phx-value-dir="1"
          class="py-12 rounded-xl bg-amber-500 text-zinc-950 text-3xl font-bold active:bg-amber-400"
        >
          →
        </button>
      </section>
    </main>
    """
  end

  def handle_event("step", %{"dir" => dir}, socket) do
    index =
      (socket.assigns.index + String.to_integer(dir))
      |> max(0)
      |> min(length(socket.assigns.deck.slides) - 1)

    Phoenix.PubSub.broadcast_from(
      Uitstalling.PubSub,
      self(),
      socket.assigns.topic,
      {:goto, index}
    )

    {:noreply, assign(socket, index: index)}
  end

  # Keep the remote in sync when the presenter uses the keyboard instead.
  def handle_info({:goto, index}, socket) do
    index = index |> max(0) |> min(length(socket.assigns.deck.slides) - 1)
    {:noreply, assign(socket, index: index)}
  end

  # The deck was edited — reload it so labels/notes stay accurate.
  def handle_info(:deck_updated, socket) do
    deck = Decks.deck!(socket.assigns.deck_id)
    index = min(socket.assigns.index, length(deck.slides) - 1)
    {:noreply, assign(socket, deck: deck, index: index)}
  end

  def handle_info(:queue_updated, socket), do: {:noreply, socket}

  defp slide_label(%Slide{} = slide) do
    text = slide.fields["heading"] || slide.fields["body"] || slide.layout

    text
    |> String.replace(~r/[*~=`]/, "")
    |> String.replace("\n", " ")
    |> String.slice(0, 90)
  end
end
