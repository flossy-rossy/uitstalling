defmodule UitstallingWeb.WritingProjectLive do
  @moduledoc """
  One project: its chapters, plan elements, and plan maps, plus the
  project-level settings (title, theme, font). Owner-only, like everything
  under /write.
  """

  use UitstallingWeb, :live_view

  alias Uitstalling.Accounts
  alias Uitstalling.Writing
  alias UitstallingWeb.WritingComponents

  import UitstallingWeb.WritingComponents, only: [type_dropdown: 1]

  @element_types Uitstalling.Writing.element_types()
  @themes Uitstalling.Writing.themes()
  @fonts Uitstalling.Writing.fonts()

  def mount(%{"project_id" => project_id}, _session, socket) do
    user = socket.assigns.current_user

    cond do
      is_nil(user) ->
        {:ok,
         socket
         |> put_flash(:error, "Sign in to write")
         |> redirect(to: ~p"/auth/login?return_to=#{"/write/#{project_id}"}")}

      not (Accounts.can_author?(user) and Writing.owned_by?(project_id, user.id)) ->
        {:ok, socket |> put_flash(:error, "No such project") |> redirect(to: ~p"/write")}

      true ->
        {:ok,
         socket
         |> assign(
           renaming: false,
           create_error: nil,
           element_type: "character",
           type_menu: false
         )
         |> load_project(project_id)}
    end
  end

  defp load_project(socket, project_id) do
    project = Writing.get_project!(project_id, socket.assigns.current_user.id)
    title = Writing.project_title(project)

    assign(socket,
      project: project,
      title: title,
      page_title: title,
      docs: Writing.list_docs(project)
    )
  end

  def handle_event("create_doc", %{"title" => title, "kind" => kind}, socket)
      when kind in ~w(chapter planning) do
    case Writing.create_doc(socket.assigns.project, kind, title) do
      {:ok, doc_id} ->
        {:noreply, push_navigate(socket, to: ~p"/write/#{socket.assigns.project.id}/#{doc_id}")}

      {:error, [error]} ->
        {:noreply, assign(socket, create_error: error)}
    end
  end

  def handle_event("create_element", %{"name" => name}, socket) do
    case Writing.create_element(socket.assigns.project, socket.assigns.element_type, name) do
      {:ok, doc_id} ->
        {:noreply, push_navigate(socket, to: ~p"/write/#{socket.assigns.project.id}/#{doc_id}")}

      {:error, [error]} ->
        {:noreply, assign(socket, create_error: error)}
    end
  end

  def handle_event("toggle_type_menu", _params, socket) do
    {:noreply, assign(socket, type_menu: not socket.assigns.type_menu)}
  end

  def handle_event("pick_type", %{"type" => type}, socket) when type in @element_types do
    {:noreply, assign(socket, element_type: type, type_menu: false)}
  end

  def handle_event("start_rename", _params, socket) do
    {:noreply, assign(socket, renaming: true)}
  end

  def handle_event("cancel_rename", _params, socket) do
    {:noreply, assign(socket, renaming: false)}
  end

  def handle_event("save_title", %{"title" => title}, socket) do
    case Writing.rename_project(socket.assigns.project, title) do
      :ok ->
        {:noreply, socket |> assign(renaming: false) |> load_project(socket.assigns.project.id)}

      {:error, _} ->
        {:noreply, assign(socket, renaming: false)}
    end
  end

  def handle_event("set_theme", %{"theme" => theme}, socket) when theme in @themes do
    :ok = Writing.set_theme(socket.assigns.project, theme)
    {:noreply, load_project(socket, socket.assigns.project.id)}
  end

  def handle_event("set_font", %{"font" => font}, socket) when font in @fonts do
    :ok = Writing.set_font(socket.assigns.project, font)
    {:noreply, load_project(socket, socket.assigns.project.id)}
  end

  def handle_event("delete_doc", %{"id" => doc_id}, socket) do
    :ok = Writing.delete_doc(socket.assigns.project, doc_id)
    {:noreply, load_project(socket, socket.assigns.project.id)}
  end

  def handle_event("delete_project", _params, socket) do
    :ok = Writing.delete_project(socket.assigns.project)
    {:noreply, push_navigate(socket, to: ~p"/write")}
  end

  def render(assigns) do
    assigns =
      assigns
      |> assign(:palette, WritingComponents.page_theme(assigns.project.theme))
      |> assign(:font, WritingComponents.font_class(assigns.project.font))
      |> assign(:chapters, Enum.filter(assigns.docs, &(&1.kind == "chapter")))
      |> assign(:sheets, Enum.filter(assigns.docs, &(&1.kind == "planning")))
      |> assign(:elements, Enum.filter(assigns.docs, &(&1.kind == "element")))

    ~H"""
    <main class={["min-h-dvh px-8 sm:px-16 py-16", @font, @palette.bg, @palette.ink]}>
      <div class="max-w-3xl mx-auto">
        <header>
          <div class="flex items-center justify-between gap-4 flex-wrap">
            <.link
              navigate={~p"/write"}
              class={["font-mono text-xs", @palette.muted, "hover:underline"]}
            >
              ← your shelf
            </.link>
            <button
              phx-click="delete_project"
              data-confirm={"Delete “#{@title}” and everything in it? There is no undo for this."}
              class={["font-mono text-xs", @palette.faint, "hover:text-red-600"]}
            >
              delete project
            </button>
          </div>

          <h1
            :if={not @renaming}
            phx-click="start_rename"
            class="mt-6 text-5xl font-bold leading-tight cursor-text"
            title="Rename"
          >
            {@title}
          </h1>
          <form :if={@renaming} phx-submit="save_title" class="mt-6 flex gap-3">
            <input
              type="text"
              name="title"
              value={@title}
              required
              autofocus
              autocomplete="off"
              class={[
                "flex-1 text-3xl font-bold rounded-lg px-3 py-2 bg-transparent border",
                @palette.rule,
                "focus:outline-none"
              ]}
            />
            <button type="submit" class="px-4 rounded-lg bg-stone-900 text-stone-50 font-semibold">
              Save
            </button>
            <button
              type="button"
              phx-click="cancel_rename"
              class={["font-mono text-xs", @palette.muted]}
            >
              cancel
            </button>
          </form>
        </header>

        <section class="mt-12">
          <p class={["font-mono text-xs tracking-wider", @palette.muted]}>CHAPTERS</p>

          <div class="mt-4 grid gap-2">
            <div
              :for={{doc, i} <- Enum.with_index(@chapters)}
              class={[
                "group flex items-center gap-4 rounded-lg border px-5 py-4",
                @palette.rule,
                @palette.hover
              ]}
            >
              <span class={["font-mono text-sm w-8 shrink-0", @palette.faint]}>{i + 1}</span>
              <.link navigate={~p"/write/#{@project.id}/#{doc.id}"} class="flex-1 min-w-0">
                <span class="text-xl font-semibold group-hover:underline decoration-1 underline-offset-4">
                  {doc.title}
                </span>
                <span class={["ml-3 font-mono text-xs", @palette.muted]}>{doc.word_count} words</span>
              </.link>
              <button
                phx-click="delete_doc"
                phx-value-id={doc.id}
                data-confirm={"Delete “#{doc.title}”?"}
                class={[
                  "opacity-0 group-hover:opacity-100 font-mono text-xs",
                  @palette.faint,
                  "hover:text-red-600"
                ]}
              >
                delete
              </button>
            </div>
          </div>

          <form id="new-chapter-form" phx-submit="create_doc" class="mt-4 flex gap-3">
            <input type="hidden" name="kind" value="chapter" />
            <input
              type="text"
              name="title"
              required
              placeholder="Next chapter title…"
              autocomplete="off"
              class={[
                "flex-1 rounded-lg px-4 py-3 bg-transparent border",
                @palette.rule,
                "placeholder:opacity-50 focus:outline-none"
              ]}
            />
            <button
              type="submit"
              class="px-5 rounded-lg bg-stone-900 text-stone-50 font-semibold hover:bg-stone-700 transition"
            >
              + Chapter
            </button>
          </form>
          <p :if={@create_error} class="mt-2 text-sm text-red-700">{@create_error}</p>
        </section>

        <section class="mt-12">
          <div class="flex items-center justify-between gap-4">
            <p class={["font-mono text-xs tracking-wider", @palette.muted]}>PLAN · YOUR WORLD</p>
            <.link
              :if={@elements != []}
              navigate={~p"/write/#{@project.id}/map"}
              class={["font-mono text-xs", @palette.accent, "hover:underline"]}
            >
              ⬡ story map →
            </.link>
          </div>

          <div class="mt-4 flex flex-wrap gap-2">
            <.link
              :for={element <- @elements}
              navigate={~p"/write/#{@project.id}/#{element.id}"}
              class={[
                "inline-flex items-center gap-2 rounded-full ring-1 px-3 py-1.5 text-sm font-semibold transition",
                WritingComponents.element_chip(element.element_type, @palette.light),
                @palette.hover
              ]}
            >
              {element.title}
              <span class="font-mono text-[10px] uppercase tracking-wider opacity-60">
                {element.element_type}
              </span>
            </.link>
          </div>

          <form phx-submit="create_element" class="mt-4 flex items-center gap-3 flex-wrap">
            <.type_dropdown
              picked={@element_type}
              open={@type_menu}
              toggle="toggle_type_menu"
              pick="pick_type"
              palette={@palette}
            />
            <input
              type="text"
              name="name"
              required
              placeholder="A character, faction, place, theme…"
              autocomplete="off"
              class={[
                "flex-1 min-w-48 rounded-lg px-4 py-3 bg-transparent border",
                @palette.rule,
                "placeholder:opacity-50 focus:outline-none"
              ]}
            />
            <button
              type="submit"
              class="px-5 rounded-lg bg-stone-900 text-stone-50 font-semibold hover:bg-stone-700 transition"
            >
              + Element
            </button>
          </form>
        </section>

        <section class="mt-12">
          <p class={["font-mono text-xs tracking-wider", @palette.muted]}>PLAN MAPS</p>

          <div class="mt-4 grid gap-2">
            <div
              :for={doc <- @sheets}
              class={[
                "group flex items-center gap-4 rounded-lg border px-5 py-4",
                @palette.rule,
                @palette.hover
              ]}
            >
              <span class={["font-mono text-sm w-8 shrink-0", @palette.faint]}>✦</span>
              <.link navigate={~p"/write/#{@project.id}/#{doc.id}"} class="flex-1 min-w-0">
                <span class="text-xl font-semibold group-hover:underline decoration-1 underline-offset-4">
                  {doc.title}
                </span>
              </.link>
              <button
                phx-click="delete_doc"
                phx-value-id={doc.id}
                data-confirm={"Delete “#{doc.title}”?"}
                class={[
                  "opacity-0 group-hover:opacity-100 font-mono text-xs",
                  @palette.faint,
                  "hover:text-red-600"
                ]}
              >
                delete
              </button>
            </div>
          </div>

          <form id="new-sheet-form" phx-submit="create_doc" class="mt-4 flex gap-3">
            <input type="hidden" name="kind" value="planning" />
            <input
              type="text"
              name="title"
              required
              placeholder="A plan map — people, places, the big picture…"
              autocomplete="off"
              class={[
                "flex-1 rounded-lg px-4 py-3 bg-transparent border",
                @palette.rule,
                "placeholder:opacity-50 focus:outline-none"
              ]}
            />
            <button
              type="submit"
              class="px-5 rounded-lg bg-stone-900 text-stone-50 font-semibold hover:bg-stone-700 transition"
            >
              + Map
            </button>
          </form>
        </section>

        <section class={["mt-14 pt-8 border-t", @palette.rule]}>
          <p class={["font-mono text-xs tracking-wider", @palette.muted]}>LOOK</p>

          <div class="mt-4 flex items-center gap-3 flex-wrap">
            <button
              :for={theme <- Uitstalling.Writing.themes()}
              phx-click="set_theme"
              phx-value-theme={theme}
              title={theme}
              class={[
                "w-9 h-9 rounded-full ring-2 transition",
                WritingComponents.swatch(theme),
                if(@project.theme == theme, do: "scale-110", else: "opacity-60 hover:opacity-100")
              ]}
            ></button>
          </div>

          <div class="mt-6 flex items-center gap-2 flex-wrap">
            <button
              :for={font <- Uitstalling.Writing.fonts()}
              phx-click="set_font"
              phx-value-font={font}
              class={[
                "px-4 py-2 rounded-lg border text-lg transition",
                WritingComponents.font_class(font),
                @palette.rule,
                if(@project.font == font,
                  do: "font-bold underline underline-offset-4",
                  else: @palette.muted
                )
              ]}
            >
              {WritingComponents.font_label(font)}
            </button>
          </div>
        </section>
      </div>
    </main>
    """
  end
end
