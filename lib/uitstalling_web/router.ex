defmodule UitstallingWeb.Router do
  use UitstallingWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {UitstallingWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug UitstallingWeb.UserAuth
  end

  # Browser-ish pipeline for the WebAuthn ceremony: it needs the session + CSRF
  # (so it can't be a pure API pipeline), but the begin/complete endpoints
  # respond JSON to fetch(), so it also negotiates json. Pages render html.
  pipeline :auth_browser do
    plug :accepts, ["html", "json"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {UitstallingWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug UitstallingWeb.UserAuth
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/auth", UitstallingWeb do
    pipe_through :auth_browser

    get "/login", AuthController, :login_page
    get "/signup", AuthController, :signup_page
    post "/login/begin", AuthController, :login_begin
    post "/login/complete", AuthController, :login_complete
    post "/register/begin", AuthController, :register_begin
    post "/register/complete", AuthController, :register_complete
    delete "/logout", AuthController, :logout
    get "/logout", AuthController, :logout
  end

  scope "/", UitstallingWeb do
    pipe_through :browser

    # Asset bytes — public like the decks that embed them
    get "/a/:id", AssetController, :show

    # PDF export: /print is the dead render the app's own headless Chrome
    # prints (public, like presenting); /deck/:id/pdf generates synchronously
    # (direct/scripted use); /pdf/:token serves a pre-generated file parked
    # by the deck page's background export.
    get "/deck/:id/print", DeckPdfController, :print
    get "/deck/:id/pdf", DeckPdfController, :download
    get "/pdf/:token", DeckPdfController, :fetch

    live_session :deck, layout: false, on_mount: {UitstallingWeb.UserAuth, :default} do
      live "/", HomeLive, :index
      live "/new", NewDeckLive, :new
      live "/deck/:id", DeckLive, :show
      live "/deck/:id/remote", DeckRemoteLive, :show
    end

    # Writing is private end to end — owner-only LiveViews, no public slugs,
    # nothing here may ever move into the catch-all scope below.
    get "/write/:project_id/image/:id", WritingImageController, :show

    live_session :writing, layout: false, on_mount: {UitstallingWeb.UserAuth, :default} do
      live "/write", WritingLive, :index
      live "/write/:project_id", WritingProjectLive, :show
      live "/write/:project_id/map", WritingMapLive, :show
      live "/write/:project_id/:doc_id", WritingDocLive, :show
    end
  end

  # Other scopes may use custom stacks.
  # scope "/api", UitstallingWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:uitstalling, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: UitstallingWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end

  # Public slug routes — LAST on purpose: /:user_slug is a catch-all, so
  # every named route above (incl. /dev) must get first pick. Slug
  # generation also refuses the reserved segments (Uitstalling.Slug).
  scope "/", UitstallingWeb do
    pipe_through :browser

    live_session :public, layout: false, on_mount: {UitstallingWeb.UserAuth, :default} do
      live "/:user_slug", UserLive, :show
      live "/:user_slug/:deck_slug", DeckLive, :show
      live "/:user_slug/:deck_slug/remote", DeckRemoteLive, :show
    end
  end
end
