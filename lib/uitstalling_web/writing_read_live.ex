defmodule UitstallingWeb.WritingReadLive do
  @moduledoc """
  Read / reference mode — the doc's prose rendered (Markdown → safe HTML via
  MDEx) instead of edit-mode textareas. Two shapes, one module:

    * `:doc` (`/write/:project_id/:doc_id/read`) — one chapter, plan map, or
      element, read-only. Reference mode for planning pages.
    * `:project` (`/write/:project_id/read`) — every chapter in book order in
      one flowing manuscript; click a chapter to jump into its editor.

  Owner-only like everything under /write. Decrypt-heavy, so content streams
  in from the ProjectServer via `start_async` behind a spinner.
  """

  use UitstallingWeb, :live_view

  alias Uitstalling.Accounts
  alias Uitstalling.Writing
  alias Uitstalling.Writing.ProjectServer
  alias UitstallingWeb.WritingComponents

  import UitstallingWeb.WritingComponents, only: [loading: 1]

  def mount(params, _session, socket) do
    user = socket.assigns.current_user
    project_id = params["project_id"]
    doc_id = params["doc_id"]

    cond do
      is_nil(user) ->
        {:ok,
         socket
         |> put_flash(:error, "Sign in to write")
         |> redirect(to: ~p"/auth/login?return_to=/write")}

      not (Accounts.can_author?(user) and Writing.owned_by?(project_id, user.id)) ->
        {:ok, socket |> put_flash(:error, "No such project") |> redirect(to: ~p"/write")}

      true ->
        project = Writing.get_project!(project_id, user.id)

        {:ok,
         socket
         |> assign(
           project: project,
           doc_id: doc_id,
           mode: if(doc_id, do: :doc, else: :project),
           loaded: false,
           page_title: "…",
           title: nil,
           kind: nil,
           element_type: nil,
           sections: [],
           links: %{},
           mentions: [],
           registry: Writing.element_type_registry(user)
         )
         |> start_async(:load, fn -> load(project, doc_id) end)}
    end
  end

  # One doc → one section; whole project → its chapters in order. `links`
  # resolves `[[wiki-links]]` (any doc's title → its read view) and is the
  # same for both modes.
  defp load(project, doc_id) do
    docs = Writing.list_docs(project)

    links =
      for d <- docs,
          into: %{},
          do: {String.downcase(d.title), "/write/#{project.id}/#{d.id}/read"}

    sections =
      cond do
        doc_id ->
          {raw, _seq, title} = ProjectServer.checkout_doc(project.id, doc_id)
          doc = Enum.find(docs, &(&1.id == doc_id))

          [
            %{
              id: doc_id,
              title: title,
              kind: doc.kind,
              element_type: doc.element_type,
              blocks: raw["blocks"]
            }
          ]

        true ->
          for d <- docs, d.kind == "chapter" do
            {raw, _seq, title} = ProjectServer.checkout_doc(project.id, d.id)
            %{id: d.id, title: title, kind: "chapter", element_type: nil, blocks: raw["blocks"]}
          end
      end

    # "Mentioned in": which other docs' prose wiki-links point at this page.
    # Only for a single doc — the whole-manuscript view is a reading flow.
    mentions =
      if doc_id do
        sources =
          for d <- docs, d.id != doc_id do
            {raw, _seq, title} = ProjectServer.checkout_doc(project.id, d.id)

            %{
              id: d.id,
              title: title,
              kind: d.kind,
              element_type: d.element_type,
              blocks: raw["blocks"]
            }
          end

        Writing.scan_mentions(hd(sections).title, sources)
      else
        []
      end

    title = if doc_id, do: hd(sections).title, else: ProjectServer.title(project.id)
    %{title: title, sections: sections, links: links, mentions: mentions}
  end

  def handle_async(:load, {:ok, data}, socket) do
    {:noreply,
     assign(socket,
       loaded: true,
       page_title: data.title,
       title: data.title,
       sections: data.sections,
       links: data.links,
       mentions: data.mentions
     )}
  end

  def handle_async(:load, {:exit, reason}, socket) do
    require Logger
    Logger.error("writing read load failed: #{inspect(reason)}")

    {:noreply,
     socket
     |> put_flash(:error, "Couldn't open that.")
     |> redirect(to: ~p"/write/#{socket.assigns.project.id}")}
  end

  # The user's bullet_style setting as a CSS list-style-type value; strings
  # (dash) are custom markers, keywords (disc/circle/square) are built in.
  defp bullet_css("dash"), do: ~s("–  ")
  defp bullet_css(style) when style in ~w(disc circle square), do: style
  defp bullet_css(_), do: "disc"

  def render(assigns) do
    assigns =
      assigns
      |> assign(:palette, WritingComponents.page_theme(assigns.project.theme))
      |> assign(:font, WritingComponents.font_class(assigns.project.font))
      |> assign(:bullet, bullet_css(Accounts.settings(assigns.current_user).bullet_style))

    ~H"""
    <main
      class={["min-h-dvh", @font, @palette.bg, @palette.ink]}
      style={"--bullet: #{@bullet}"}
    >
      <header class={["border-b", @palette.rule]}>
        <div class="max-w-2xl mx-auto px-6 py-3 flex items-center gap-4">
          <.link
            navigate={~p"/write/#{@project.id}"}
            class={["font-mono text-xs", @palette.muted, "hover:underline"]}
          >
            ← project
          </.link>
          <p class="flex-1 text-center font-semibold truncate">{@title}</p>
          <.link
            :if={@mode == :doc}
            navigate={~p"/write/#{@project.id}/#{@doc_id}"}
            class={["font-mono text-xs", @palette.accent, "hover:underline"]}
          >
            ✎ edit
          </.link>
          <span
            :if={@mode == :project}
            class={["font-mono text-xs", @palette.faint]}
          >
            manuscript
          </span>
        </div>
      </header>

      <.loading :if={not @loaded} palette={@palette} label="setting the type…" />

      <article :if={@loaded} class="max-w-2xl mx-auto px-6 py-16">
        <p :if={@sections == []} class={["text-lg text-center", @palette.muted]}>
          Nothing to read here yet.
        </p>

        <section :for={section <- @sections} class="mb-20">
          <header :if={@mode == :project} class={["mb-8 pb-2 border-b", @palette.rule]}>
            <.link
              navigate={~p"/write/#{@project.id}/#{section.id}"}
              class="text-3xl font-bold hover:underline decoration-1 underline-offset-4"
            >
              {section.title}
            </.link>
          </header>

          <p
            :if={@mode == :doc and section.element_type}
            class={[
              "mb-8 inline-flex items-center rounded-full ring-1 px-3 py-1 font-mono text-[10px] uppercase tracking-wider",
              WritingComponents.element_chip(@registry, section.element_type, @palette.light)
            ]}
          >
            {section.element_type}
          </p>

          <.read_block
            :for={block <- section.blocks}
            block={block}
            project_id={@project.id}
            palette={@palette}
            links={@links}
          />
        </section>

        <section
          :if={@mode == :doc and @mentions != []}
          class={["mt-16 pt-8 border-t", @palette.rule]}
        >
          <p class={["font-mono text-[10px] uppercase tracking-wider mb-6", @palette.faint]}>
            mentioned in
          </p>
          <ul class="space-y-6">
            <li :for={m <- @mentions}>
              <.link
                navigate={~p"/write/#{@project.id}/#{m.id}/read"}
                class="inline-flex items-center gap-2 font-semibold hover:underline decoration-1 underline-offset-4"
              >
                {m.title}
                <span class={[
                  "font-mono text-[10px] uppercase tracking-wider not-italic",
                  @palette.faint
                ]}>
                  {mention_kind(@registry, m)}
                </span>
              </.link>
              <ul class={["mt-2 space-y-1.5 border-l-2 pl-4", @palette.rule]}>
                <li :for={snippet <- m.snippets} class={["text-sm leading-relaxed", @palette.muted]}>
                  “{snippet}”
                </li>
              </ul>
            </li>
          </ul>
        </section>
      </article>
    </main>
    """
  end

  # A mention's kind label: "chapter", or the tag's element-type label.
  defp mention_kind(_registry, %{kind: "chapter"}), do: "chapter"

  defp mention_kind(registry, %{element_type: type}) do
    case registry[type] do
      %{label: label} -> label
      _ -> type
    end
  end

  attr :block, :map, required: true
  attr :project_id, :string, required: true
  attr :palette, :map, required: true
  attr :links, :map, required: true

  defp read_block(%{block: %{"type" => "heading"}} = assigns) do
    ~H"""
    <h2 class="text-2xl font-bold mt-10 mb-3">{@block["text"]}</h2>
    """
  end

  defp read_block(%{block: %{"type" => "scene_break"}} = assigns) do
    ~H"""
    <div class={["text-center py-6 tracking-[1em] select-none", @palette.faint]}>✳ ✳ ✳</div>
    """
  end

  defp read_block(%{block: %{"type" => "epigraph"}} = assigns) do
    ~H"""
    <blockquote class="my-8 px-8 text-center italic">
      <WritingComponents.prose text={@block["text"]} links={@links} />
      <p
        :if={@block["source"] != nil and @block["source"] != ""}
        class={["mt-1 text-sm", @palette.muted]}
      >
        — {@block["source"]}
      </p>
    </blockquote>
    """
  end

  defp read_block(%{block: %{"type" => "portrait"}} = assigns) do
    ~H"""
    <figure :if={@block["image"] not in [nil, ""]} class="my-6 flex flex-col items-center gap-2">
      <img
        src={~p"/write/#{@project_id}/image/#{@block["image"]}"}
        alt={@block["caption"] || "portrait"}
        class="rounded-xl max-h-80 max-w-full shadow-md"
      />
      <figcaption :if={@block["caption"]} class={["text-sm italic", @palette.muted]}>
        {@block["caption"]}
      </figcaption>
    </figure>
    """
  end

  defp read_block(%{block: %{"type" => type}} = assigns) when type in ~w(field beat) do
    ~H"""
    <div class="mt-6">
      <p class={["font-mono text-xs uppercase tracking-widest", @palette.accent]}>
        {@block["label"]}
      </p>
      <WritingComponents.prose text={@block["text"]} links={@links} />
    </div>
    """
  end

  defp read_block(%{block: %{"type" => "character"}} = assigns) do
    ~H"""
    <div class="mt-6">
      <p class="text-xl font-bold">{@block["name"]}</p>
      <WritingComponents.prose text={@block["text"]} links={@links} />
    </div>
    """
  end

  # node (map dots) has nothing to read; everything else is prose.
  defp read_block(%{block: %{"type" => "node"}} = assigns), do: ~H""

  defp read_block(assigns) do
    ~H"""
    <WritingComponents.prose text={@block["text"]} links={@links} />
    """
  end
end
