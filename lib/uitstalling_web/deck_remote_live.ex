defmodule UitstallingWeb.DeckRemoteLive do
  @moduledoc """
  Phone remote + presenter view for a deck: prev/next buttons, position,
  and the current slide's speaker notes. Drives every connected viewer of
  the same deck over PubSub — which is exactly why it's owner-only: viewing
  is public-by-link, but only the deck's owner may steer everyone's slides.
  """

  use UitstallingWeb, :live_view

  alias Uitstalling.Accounts
  alias Uitstalling.Decks
  alias Uitstalling.Decks.Slide
  alias UitstallingWeb.DeckComponents

  def mount(%{"user_slug" => user_slug, "deck_slug" => deck_slug}, _session, socket) do
    with %{} = owner <- Accounts.get_user_by_slug(user_slug),
         deck_id when is_binary(deck_id) <- Decks.deck_id_for(owner.id, deck_slug) do
      mount_remote(deck_id, socket, "/#{user_slug}/#{deck_slug}")
    else
      _ -> {:ok, socket |> put_flash(:error, "No such presentation") |> redirect(to: ~p"/")}
    end
  end

  def mount(%{"id" => deck_id}, _session, socket) do
    mount_remote(deck_id, socket, "/deck/#{deck_id}")
  end

  defp mount_remote(deck_id, socket, base_path) do
    user = socket.assigns.current_user

    cond do
      not Decks.exists?(deck_id) ->
        {:ok, socket |> put_flash(:error, "No such presentation") |> redirect(to: ~p"/")}

      is_nil(user) ->
        {:ok,
         socket
         |> put_flash(:error, "Sign in to use the remote")
         |> redirect(to: ~p"/auth/login?return_to=#{base_path <> "/remote"}")}

      not (Accounts.can_author?(user) and Decks.owned_by?(deck_id, user.id)) ->
        {:ok,
         socket
         |> put_flash(:error, "Only this deck's presenter can use the remote")
         |> redirect(to: base_path)}

      true ->
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
           palette: DeckComponents.remote_palette(deck.theme, deck.accent),
           index: 0
         )}
    end
  end

  def render(assigns) do
    assigns = assign(assigns, :slide, Enum.at(assigns.deck.slides, assigns.index))

    ~H"""
    <main class={["min-h-dvh flex flex-col p-6", @palette.bg]}>
      <header>
        <p class={["font-mono text-xs tracking-wider", @palette.accent_text]}>
          REMOTE · {@deck.title}
        </p>
        <p class={["mt-2 font-mono text-sm", @palette.faint]}>
          {@index + 1} / {length(@deck.slides)}
        </p>
      </header>

      <section class="flex-1 mt-8">
        <p class={["font-mono text-xs mb-2 uppercase", @palette.faint]}>{@slide.layout}</p>
        <p class="text-2xl font-semibold leading-snug">{slide_label(@slide)}</p>

        <div :if={@slide.notes} class={["mt-6 p-4 rounded-lg", @palette.card]}>
          <p class={["font-mono text-xs mb-2", @palette.accent_text]}>NOTES</p>
          <p class={["leading-relaxed", @palette.muted]}>{@slide.notes}</p>
        </div>
      </section>

      <section class="grid grid-cols-2 gap-4 pb-4">
        <button
          phx-click="step"
          phx-value-dir="-1"
          class={["py-12 rounded-xl text-3xl font-bold", @palette.button]}
        >
          ←
        </button>
        <button
          phx-click="step"
          phx-value-dir="1"
          class={["py-12 rounded-xl text-3xl font-bold", @palette.accent_button]}
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

  # The deck was edited — reload it so labels/notes (and the theme the
  # remote wears) stay accurate.
  def handle_info(:deck_updated, socket) do
    deck = Decks.deck!(socket.assigns.deck_id)
    index = min(socket.assigns.index, length(deck.slides) - 1)

    {:noreply,
     assign(socket,
       deck: deck,
       palette: DeckComponents.remote_palette(deck.theme, deck.accent),
       index: index
     )}
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
