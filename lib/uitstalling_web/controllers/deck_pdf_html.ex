defmodule UitstallingWeb.DeckPdfHTML do
  @moduledoc """
  The dead print view Chrome renders to PDF: the same slide components as
  the live deck — no JS, no nav chrome — restyled so each slide is exactly
  one 16:9 page. Page geometry must stay in sync with `Uitstalling.Decks.Pdf`.
  """

  use UitstallingWeb, :html

  import UitstallingWeb.DeckComponents

  def print(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <title>{@deck.title}</title>
        <link rel="stylesheet" href={~p"/assets/css/app.css"} />
        <style>
          @page {
            size: 13.333in 7.5in;
            margin: 0;
          }

          html,
          body {
            margin: 0;
            padding: 0;
          }

          /* One slide = one page: defeat the screen-height styling, shrink
             the tall screen padding, and clip what a dense slide can't fit. */
          section[data-slide-id] {
            width: 13.333in;
            height: 7.5in;
            min-height: 0 !important;
            padding-top: 2.5rem !important;
            padding-bottom: 2.5rem !important;
            overflow: hidden;
            break-after: page;
            break-inside: avoid;
          }

          section[data-slide-id]:last-of-type {
            break-after: auto;
          }
        </style>
        <script>
          // A dense slide (a tall flow, a long table) zooms down to fit its
          // page instead of losing its top and bottom to overflow:hidden.
          // Runs on load — after images have sized, and before Chrome
          // prints (printing waits for the load event).
          window.addEventListener("load", () => {
            for (const section of document.querySelectorAll("section[data-slide-id]")) {
              const inner = section.querySelector(":scope > div");
              if (!inner) continue;
              const style = getComputedStyle(section);
              const avail = section.clientHeight -
                parseFloat(style.paddingTop) - parseFloat(style.paddingBottom);
              // zoom is linear, so one pass lands; loop mops up rounding
              for (let i = 0; i < 3; i++) {
                const height = inner.getBoundingClientRect().height;
                if (height <= avail) break;
                inner.style.zoom = (parseFloat(inner.style.zoom) || 1) * (avail / height);
              }
            }
          });
        </script>
      </head>
      <body>
        <.slide
          :for={{slide, i} <- Enum.with_index(@deck.slides)}
          deck={@deck}
          slide={slide}
          index={i}
          print
        />
      </body>
    </html>
    """
  end
end
