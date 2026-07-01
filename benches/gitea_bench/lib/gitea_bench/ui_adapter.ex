defmodule GiteaBench.UiAdapter do
  @moduledoc """
  Executes the model's intents by driving Gitea's web UI with Playwright.

  Every *mutation* is performed through the browser exactly as a person would:
  fill the form, click the button, toggle the label dropdown. The resulting event
  is then built from the same neutral observation read the API adapter uses
  (`GiteaBench.Gitea`), so the differential oracle isolates the one thing that
  differs between the two adapters: how the change was made.

  Gitea's UI can only create a repo under the acting account, so to keep true
  parity with the API transport the adapter logs in *as* the relevant user. Each
  user gets its **own browser context** (isolated cookies), logged in once on
  first use and reused, so switching users is free after the first login. Every
  command then runs on a **fresh page** opened in that context: a page is never
  shared between commands, so one command's asynchronous after-effects (a
  form-submit reload, a live-update redirect) can never land on the next
  command's page and navigate it away mid-interaction. See `page_for/2`.

  Config (`opts`/`adapter_config`): `:base_url` (required), `:admin_user`,
  `:admin_password`, and `:seed_bug` (when true, label creation fills the wrong
  colour: a deliberate transport bug the oracle is meant to catch).
  """

  use PropertyDamage.Adapter

  alias GiteaBench.Gitea
  alias Playwright.{Browser, BrowserContext, Page}

  alias GiteaBench.Commands.{
    AddLabelToIssue,
    CloseIssue,
    CreateIssue,
    CreateLabel,
    CreateRepo,
    CreateUser
  }

  @nav_timeout 10_000
  @settle_timeout 6_000
  @seeded_wrong_color "#ff0000"

  @impl true
  def setup(config) do
    client = Gitea.new(config)
    :ok = Gitea.ensure_ready(client)
    :ok = Gitea.reset!(client)

    {:ok, browser} = Playwright.launch(:chromium, %{headless: true})
    # One logged-in browser context per user, created lazily on first use:
    # %{user => context}. Each command opens a *fresh page* in the user's context
    # (see page_for/2), so it never inherits an in-flight navigation or other
    # residue from the previous command's page.
    {:ok, sessions} = Agent.start_link(fn -> %{} end)

    {:ok,
     %{
       client: client,
       browser: browser,
       sessions: sessions,
       base_url: client.base_url,
       seed_bug: Map.get(config, :seed_bug, false)
     }}
  end

  @impl true
  def teardown(%{browser: browser, sessions: sessions}) do
    Agent.stop(sessions)
    # Closing the browser tears down every per-user context and page it owns.
    Browser.close(browser)
    :ok
  end

  def teardown(_), do: :ok

  @impl true
  def execute(%CreateUser{login: login, email: email}, ctx, _runtime) do
    page = page_for(ctx, ctx.client.admin_user)

    navigate(page, ctx.base_url <> "/admin/users/new", "input[name=user_name]")
    Page.fill(page, "input[name=user_name]", login)
    Page.fill(page, "input[name=email]", email)
    Page.fill(page, "input[name=password]", Gitea.user_password())
    # The form checks "must change password" by default; clear it directly on the
    # input (Semantic UI hides the real checkbox) so the user can log in normally
    # when an adapter later acts as them.
    Page.evaluate(
      page,
      "() => { const c = document.querySelector('input[name=must_change_password]'); if (c) c.checked = false; }"
    )

    Page.click(page, ~s|button:has-text("Create User Account")|)

    event = settle(fn -> Gitea.user_event(ctx.client, login) end, &(&1.login == login))
    {:ok, [event]}
  end

  def execute(%CreateRepo{owner: owner, name: name}, ctx, _runtime) do
    page = page_for(ctx, owner)

    navigate(page, ctx.base_url <> "/repo/create", "input[name=repo_name]")
    Page.fill(page, "input[name=repo_name]", name)
    Page.click(page, ~s|button:has-text("Create Repository")|)

    event = settle(fn -> Gitea.repo_event(ctx.client, owner, name) end, &(&1.full_name != nil))
    {:ok, [event]}
  end

  def execute(%CreateIssue{repo: full_name, title: title}, ctx, _runtime) do
    {owner, repo} = GiteaBench.split_full_name(full_name)
    page = page_for(ctx, owner)

    navigate(page, ctx.base_url <> "/#{owner}/#{repo}/issues/new", "input[name=title]")
    Page.fill(page, "input[name=title]", title)
    Page.click(page, ~s|button:has-text("Create Issue")|)
    Page.wait_for_selector(page, "#status-button", %{timeout: @nav_timeout})

    number = issue_number_from_url(Page.url(page))

    event =
      settle(
        fn -> Gitea.issue_event(ctx.client, full_name, number, title) end,
        &(&1.title == title)
      )

    {:ok, [event]}
  end

  def execute(%CreateLabel{repo: full_name, name: name, color: color}, ctx, _runtime) do
    {owner, repo} = GiteaBench.split_full_name(full_name)
    page = page_for(ctx, owner)
    color = if ctx.seed_bug, do: @seeded_wrong_color, else: color

    navigate(page, ctx.base_url <> "/#{owner}/#{repo}/labels", ".new-label.button")
    Page.click(page, ".new-label.button")
    Page.fill(page, ".new-label.modal input[name=title]", name)
    Page.fill(page, ".new-label.modal input[name=color]", color)
    Page.click(page, ~s|.new-label.modal button:has-text("Create Label")|)

    event = settle(fn -> Gitea.label_event(ctx.client, full_name, name) end, &(&1.name == name))
    {:ok, [event]}
  end

  def execute(
        %AddLabelToIssue{assignment: %{repo: full_name, number: number, label: label}},
        ctx,
        _runtime
      ) do
    {owner, repo} = GiteaBench.split_full_name(full_name)
    page = page_for(ctx, owner)
    label_id = Gitea.label_id(ctx.client, owner, repo, label)

    navigate(page, ctx.base_url <> "/#{owner}/#{repo}/issues/#{number}", ".select-label.dropdown")

    item = ".select-label .menu .item[data-id='#{label_id}']"

    Page.click(page, ".select-label.dropdown")
    Page.wait_for_selector(page, item, %{timeout: @nav_timeout})

    # Gitea's dropdown item is a *toggle*: clicking an already-checked label removes
    # it. The model's AddLabelToIssue intent is idempotent-additive (it matches the
    # API transport's `POST .../labels`, which unions the label set), and the model
    # can generate a duplicate assignment for an already-labelled issue, so only
    # click when the label is not yet checked. Clicking unconditionally would
    # silently *unassign* the label and make the invariant fire on a phantom miss.
    unless Page.eval_on_selector(page, item, "el => el.classList.contains('checked')") do
      Page.click(page, item)
    end

    # Clicking outside the dropdown commits the change (Gitea posts via AJAX).
    Page.click(page, "footer")

    event =
      settle(
        fn -> Gitea.label_assigned_event(ctx.client, full_name, number, label) end,
        &(label in &1.labels)
      )

    {:ok, [event]}
  end

  def execute(%CloseIssue{target: %{repo: full_name, number: number}}, ctx, _runtime) do
    {owner, repo} = GiteaBench.split_full_name(full_name)
    page = page_for(ctx, owner)

    navigate(page, ctx.base_url <> "/#{owner}/#{repo}/issues/#{number}", "#status-button")

    Page.click(page, "#status-button")

    event =
      settle(
        fn -> Gitea.issue_closed_event(ctx.client, full_name, number) end,
        &(&1.state == "closed")
      )

    {:ok, [event]}
  end

  # --- session management ----------------------------------------------------

  # A fresh page authenticated as `user`. The per-user browser context (with its
  # login cookies) is created and logged in on first use and reused thereafter,
  # but every call returns a NEW page in that context. Reusing a single page
  # across a run's commands let a mutating command's asynchronous after-effects (a
  # form-submit reload, a live-update redirect) land on the *next* command's page
  # mid-interaction and navigate it away, so that command then waited out its
  # timeout on an element no longer present. A fresh page per command cannot
  # inherit that residue; the context (hence the login) is still shared, so this
  # costs a `new_page`, not a re-login. Pages accumulate until teardown closes the
  # browser, which is fine for a run's modest command count.
  defp page_for(ctx, user) do
    BrowserContext.new_page(context_for(ctx, user))
  end

  # Get or lazily create the logged-in context for `user`. Commands execute
  # sequentially within a run, so a plain get/create/put is race-free; the login
  # runs outside the Agent so it never holds the lock.
  defp context_for(ctx, user) do
    case Agent.get(ctx.sessions, &Map.get(&1, user)) do
      nil ->
        context = Browser.new_context(ctx.browser)
        login_page = BrowserContext.new_page(context)
        login(login_page, ctx.base_url, user, password_for(ctx, user))
        # Login set the auth cookies on the context; the login page itself is no
        # longer needed (each command opens its own fresh page).
        Page.close(login_page)
        Agent.update(ctx.sessions, &Map.put(&1, user, context))
        context

      context ->
        context
    end
  end

  defp login(page, base_url, user, password) do
    Page.goto(page, base_url <> "/user/login", %{timeout: @nav_timeout})

    # Wait for the login form to be present and visible before filling. Without
    # this, a fill/press auto-waits its full (30s) default timeout whenever the
    # form is not immediately actionable -- e.g. if /user/login redirected away
    # because the context was already authenticated.
    Page.wait_for_selector(page, "input[name=user_name]", %{
      state: "visible",
      timeout: @nav_timeout
    })

    Page.fill(page, "input[name=user_name]", user)
    Page.fill(page, "input[name=password]", password)
    Page.press(page, "input[name=password]", "Enter")

    # Login is complete once the form is gone (we have navigated to the
    # dashboard). Wait for the username field to DETACH rather than for a
    # dashboard element: Gitea renders the user's profile link (a[href="/<user>"])
    # inside the *collapsed* avatar dropdown, so it is in the DOM but not visible
    # (0x0). `wait_for_selector` waits for visibility by default, so waiting on
    # that link burns the entire timeout even though login already succeeded --
    # the original cause of intermittent ~10-30s login stalls. A failed login
    # (bad credentials) re-renders the form, so the field stays attached and this
    # correctly times out.
    Page.wait_for_selector(page, "input[name=user_name]", %{
      state: "detached",
      timeout: @nav_timeout
    })
  end

  defp password_for(ctx, user) do
    if user == ctx.client.admin_user, do: ctx.client.admin_password, else: Gitea.user_password()
  end

  # --- helpers ---------------------------------------------------------------

  # Navigate to `url` and confirm we actually arrived by waiting for `ready` (an
  # element that only exists on the destination page) to be visible; re-issue the
  # goto if we did not land.
  #
  # A page is reused across the commands of a run, and a preceding mutating
  # command can leave it with an in-flight navigation (e.g. CloseIssue clicks
  # `#status-button`, which submits a form and reloads the issue page, then
  # settles against the *API* without waiting for that reload). A single
  # `Page.goto` issued while that navigation is in flight can be superseded --
  # it returns without error but the page stays on the previous URL, so every
  # subsequent action then waits out its full timeout on an element that is not
  # there. Verifying arrival and retrying makes navigation robust against that
  # race (a re-goto after the in-flight navigation settles lands cleanly).
  defp navigate(page, url, ready, attempts \\ 4) do
    # First let any navigation the *previous* command left in flight settle. A
    # mutating command (e.g. CloseIssue clicking `#status-button`) submits a form
    # that reloads the page and returns after settling against the API, without
    # waiting for that reload; if we goto while it is in flight, our navigation is
    # superseded and the page drifts back to the old URL.
    wait_load(page)
    Page.goto(page, url, %{timeout: @nav_timeout})
    wait_load(page)

    cond do
      arrived?(page, ready, if(attempts <= 1, do: @nav_timeout, else: 1_500)) ->
        :ok

      attempts <= 1 ->
        # Out of retries: a final, full-timeout wait so a genuine failure surfaces
        # as a clear "waiting for <ready>" error rather than a silent stall.
        Page.wait_for_selector(page, ready, %{state: "visible", timeout: @nav_timeout})

      true ->
        navigate(page, url, ready, attempts - 1)
    end
  end

  defp arrived?(page, ready, timeout) do
    Page.wait_for_selector(page, ready, %{state: "visible", timeout: timeout})
    true
  rescue
    _ -> false
  end

  # Best-effort wait for the page's load event; never raises (a page with no
  # pending navigation is already loaded).
  defp wait_load(page) do
    Page.wait_for_load_state(page, "load")
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp issue_number_from_url(url) do
    [_, n] = Regex.run(~r{/issues/(\d+)}, url)
    String.to_integer(n)
  end

  # The UI mutates asynchronously (form redirects, dropdown AJAX), so poll the
  # neutral observer until it reflects the change or the budget runs out.
  defp settle(observe, predicate, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + @settle_timeout
    event = observe.()

    cond do
      predicate.(event) ->
        event

      System.monotonic_time(:millisecond) >= deadline ->
        event

      true ->
        Process.sleep(150)
        settle(observe, predicate, deadline)
    end
  end
end
