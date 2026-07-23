defmodule UitstallingWeb.WritingMapLive do
  @moduledoc """
  The story map: an Obsidian-style force-directed graph of a project's plan
  elements and the chapters they're tagged in. Layout runs client-side in a
  colocated hook (hand-rolled simulation, no JS deps); node positions are
  ephemeral — the graph is a view of the links, not a drawing to maintain.
  Clicking a node opens its doc. Owner-only like everything under /write.
  """

  use UitstallingWeb, :live_view

  alias Uitstalling.Accounts
  alias Uitstalling.Writing
  alias UitstallingWeb.WritingComponents

  def mount(%{"project_id" => project_id}, _session, socket) do
    user = socket.assigns.current_user

    cond do
      is_nil(user) ->
        {:ok,
         socket
         |> put_flash(:error, "Sign in to write")
         |> redirect(to: ~p"/auth/login?return_to=#{"/write/#{project_id}/map"}")}

      not (Accounts.can_author?(user) and Writing.owned_by?(project_id, user.id)) ->
        {:ok, socket |> put_flash(:error, "No such project") |> redirect(to: ~p"/write")}

      true ->
        project = Writing.get_project!(project_id, user.id)
        registry = Writing.element_type_registry(user)
        graph = Writing.graph(project)

        payload = %{
          nodes:
            Enum.map(graph.nodes, fn node ->
              Map.put(node, :color, WritingComponents.element_hex(registry, node.type))
            end),
          edges: graph.edges
        }

        {:ok,
         assign(socket,
           project: project,
           registry: registry,
           project_title: Writing.project_title(project),
           page_title: "Story map",
           graph_json: Jason.encode!(payload),
           node_count: length(graph.nodes),
           types: Enum.uniq(Enum.map(graph.nodes, & &1.type))
         )}
    end
  end

  def handle_event("open_node", %{"id" => doc_id}, socket) do
    {:noreply, push_navigate(socket, to: ~p"/write/#{socket.assigns.project.id}/#{doc_id}")}
  end

  def render(assigns) do
    assigns =
      assigns
      |> assign(:palette, WritingComponents.page_theme(assigns.project.theme))
      |> assign(:font, WritingComponents.font_class(assigns.project.font))
      |> assign(:map_colors, WritingComponents.map_colors(assigns.project.theme))

    ~H"""
    <main class={["min-h-dvh flex flex-col", @font, @palette.bg, @palette.ink]}>
      <header class={["border-b", @palette.rule]}>
        <div class="max-w-5xl mx-auto px-6 py-3 flex items-center gap-4 flex-wrap">
          <.link
            navigate={~p"/write/#{@project.id}"}
            class={["font-mono text-xs", @palette.muted, "hover:underline"]}
          >
            ← {@project_title}
          </.link>
          <p class="font-semibold">Story map</p>
          <div class="ml-auto flex items-center gap-3 flex-wrap">
            <span
              :for={type <- @types}
              class={[
                "inline-flex items-center gap-1.5 font-mono text-[10px] uppercase tracking-wider",
                @palette.muted
              ]}
            >
              <span
                class="inline-block w-2 h-2 rounded-full"
                style={"background: #{WritingComponents.element_hex(@registry, type)}"}
              ></span>
              {type}
            </span>
          </div>
        </div>
      </header>

      <p :if={@node_count == 0} class={["m-auto text-lg px-6 text-center", @palette.muted]}>
        The map draws itself from your plan — add elements on the project page and
        tag chapters with them.
      </p>

      <div
        :if={@node_count > 0}
        id="story-map"
        phx-hook=".StoryMap"
        phx-update="ignore"
        data-graph={@graph_json}
        data-ink={@map_colors.ink}
        data-edge={@map_colors.edge}
        class="flex-1 cursor-grab touch-none select-none"
      >
      </div>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".StoryMap">
        export default {
          mounted() {
            const {nodes, edges} = JSON.parse(this.el.dataset.graph)
            const ink = this.el.dataset.ink
            const edgeColor = this.el.dataset.edge
            const NS = "http://www.w3.org/2000/svg"

            const byId = new Map()
            nodes.forEach((n, i) => {
              // Deterministic-ish seeding on a ring: stable enough to feel
              // calm, and the simulation does the real placement.
              const angle = (i / nodes.length) * Math.PI * 2
              n.x = 400 + Math.cos(angle) * 150 + (i % 7) * 3
              n.y = 300 + Math.sin(angle) * 150 + (i % 5) * 3
              n.vx = 0
              n.vy = 0
              n.degree = 0
              byId.set(n.id, n)
            })

            const links = edges
              .map((e) => ({s: byId.get(e.source), t: byId.get(e.target)}))
              .filter((l) => l.s && l.t)
            links.forEach((l) => { l.s.degree++; l.t.degree++ })
            nodes.forEach((n) => { n.r = 7 + Math.sqrt(n.degree) * 3 })

            const svg = document.createElementNS(NS, "svg")
            svg.setAttribute("width", "100%")
            svg.setAttribute("height", "100%")
            this.el.appendChild(svg)

            const edgeEls = links.map(() => {
              const line = document.createElementNS(NS, "line")
              line.setAttribute("stroke", edgeColor)
              line.setAttribute("stroke-width", "1.5")
              svg.appendChild(line)
              return line
            })

            const nodeEls = nodes.map((n) => {
              const g = document.createElementNS(NS, "g")
              g.style.cursor = "pointer"
              const circle = document.createElementNS(NS, "circle")
              circle.setAttribute("r", n.r)
              circle.setAttribute("fill", n.color)
              circle.setAttribute("fill-opacity", "0.85")
              const label = document.createElementNS(NS, "text")
              label.textContent = n.title
              label.setAttribute("fill", ink)
              label.setAttribute("font-size", "12")
              label.setAttribute("text-anchor", "middle")
              g.appendChild(circle)
              g.appendChild(label)
              svg.appendChild(g)

              let moved = false
              g.addEventListener("pointerdown", (e) => {
                e.preventDefault()
                g.setPointerCapture(e.pointerId)
                moved = false
                n.fixed = true
                const onMove = (ev) => {
                  moved = true
                  const p = this.svgPoint(svg, ev)
                  n.x = p.x
                  n.y = p.y
                  n.vx = 0
                  n.vy = 0
                  this.energy = 1
                }
                const onUp = (ev) => {
                  g.removeEventListener("pointermove", onMove)
                  g.removeEventListener("pointerup", onUp)
                  n.fixed = false
                  this.energy = 1
                  if (!moved) this.pushEvent("open_node", {id: n.id})
                }
                g.addEventListener("pointermove", onMove)
                g.addEventListener("pointerup", onUp)
              })
              return g
            })

            this.state = {nodes, links, edgeEls, nodeEls, svg}
            this.energy = 1
            this.tick = this.tick.bind(this)
            this.raf = requestAnimationFrame(this.tick)
          },

          svgPoint(svg, e) {
            const pt = svg.createSVGPoint()
            pt.x = e.clientX
            pt.y = e.clientY
            return pt.matrixTransform(svg.getScreenCTM().inverse())
          },

          tick() {
            const {nodes, links, edgeEls, nodeEls, svg} = this.state

            if (this.energy > 0.002) {
              // Repulsion (O(n²) — fine for a story's worth of nodes)
              for (let i = 0; i < nodes.length; i++) {
                for (let j = i + 1; j < nodes.length; j++) {
                  const a = nodes[i], b = nodes[j]
                  let dx = a.x - b.x, dy = a.y - b.y
                  let d2 = dx * dx + dy * dy
                  if (d2 < 1) { dx = Math.random() - 0.5; dy = Math.random() - 0.5; d2 = 1 }
                  const f = Math.min(2600 / d2, 6)
                  const d = Math.sqrt(d2)
                  a.vx += (dx / d) * f; a.vy += (dy / d) * f
                  b.vx -= (dx / d) * f; b.vy -= (dy / d) * f
                }
              }
              // Springs along links
              links.forEach((l) => {
                const dx = l.t.x - l.s.x, dy = l.t.y - l.s.y
                const d = Math.sqrt(dx * dx + dy * dy) || 1
                const f = (d - 110) * 0.012
                l.s.vx += (dx / d) * f; l.s.vy += (dy / d) * f
                l.t.vx -= (dx / d) * f; l.t.vy -= (dy / d) * f
              })
              // Gentle centering + integrate
              this.energy = 0
              nodes.forEach((n) => {
                if (!n.fixed) {
                  n.vx += (400 - n.x) * 0.0015
                  n.vy += (300 - n.y) * 0.0015
                  n.vx *= 0.85
                  n.vy *= 0.85
                  n.x += n.vx
                  n.y += n.vy
                  this.energy = Math.max(this.energy, Math.abs(n.vx) + Math.abs(n.vy))
                }
              })
            }

            // Draw, and keep the viewBox fitted to the content
            links.forEach((l, i) => {
              edgeEls[i].setAttribute("x1", l.s.x)
              edgeEls[i].setAttribute("y1", l.s.y)
              edgeEls[i].setAttribute("x2", l.t.x)
              edgeEls[i].setAttribute("y2", l.t.y)
            })
            nodes.forEach((n, i) => {
              const g = nodeEls[i]
              g.querySelector("circle").setAttribute("cx", n.x)
              g.querySelector("circle").setAttribute("cy", n.y)
              const label = g.querySelector("text")
              label.setAttribute("x", n.x)
              label.setAttribute("y", n.y + n.r + 14)
            })

            const xs = nodes.map((n) => n.x), ys = nodes.map((n) => n.y)
            const pad = 80
            const minX = Math.min(...xs) - pad, maxX = Math.max(...xs) + pad
            const minY = Math.min(...ys) - pad, maxY = Math.max(...ys) + pad
            svg.setAttribute("viewBox", `${minX} ${minY} ${maxX - minX} ${maxY - minY}`)

            this.raf = requestAnimationFrame(this.tick)
          },

          destroyed() {
            cancelAnimationFrame(this.raf)
          },
        }
      </script>
    </main>
    """
  end
end
