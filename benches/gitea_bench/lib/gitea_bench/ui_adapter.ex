defmodule GiteaBench.UiAdapter do
  @moduledoc """
  Executes the model's intents by driving Gitea's web UI with Playwright.

  Every *mutation* is performed through the browser exactly as a person would:
  fill the form, click the button, toggle the label dropdown. The resulting event
  is then built from the same neutral observation read the API adapter uses
  (`GiteaBench.Gitea`), so the differential oracle isolates the one thing that
  differs between the two adapters: how the change was made.

  Gitea's UI can only create a repo under the acting account, so to keep true
  parity with the API transport the adapter logs in *as* the relevant user
  (tracked in an Agent, switched by clearing cookies and re-authenticating).

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
    context = Browser.new_context(browser)
    page = BrowserContext.new_page(context)
    {:ok, session} = Agent.start_link(fn -> nil end)

    {:ok,
     %{
       client: client,
       browser: browser,
       context: context,
       page: page,
       session: session,
       base_url: client.base_url,
       seed_bug: Map.get(config, :seed_bug, false)
     }}
  end

  @impl true
  def teardown(%{browser: browser, session: session}) do
    Agent.stop(session)
    Browser.close(browser)
    :ok
  end

  def teardown(_), do: :ok

  @impl true
  def execute(%CreateUser{login: login, email: email}, ctx, _runtime) do
    ensure_login(ctx, ctx.client.admin_user)
    page = ctx.page

    Page.goto(page, ctx.base_url <> "/admin/users/new", %{timeout: @nav_timeout})
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
    ensure_login(ctx, owner)
    page = ctx.page

    Page.goto(page, ctx.base_url <> "/repo/create", %{timeout: @nav_timeout})
    Page.fill(page, "input[name=repo_name]", name)
    Page.click(page, ~s|button:has-text("Create Repository")|)

    event = settle(fn -> Gitea.repo_event(ctx.client, owner, name) end, &(&1.full_name != nil))
    {:ok, [event]}
  end

  def execute(%CreateIssue{repo: full_name, title: title}, ctx, _runtime) do
    {owner, repo} = GiteaBench.split_full_name(full_name)
    ensure_login(ctx, owner)
    page = ctx.page

    Page.goto(page, ctx.base_url <> "/#{owner}/#{repo}/issues/new", %{timeout: @nav_timeout})
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
    ensure_login(ctx, owner)
    page = ctx.page
    color = if ctx.seed_bug, do: @seeded_wrong_color, else: color

    Page.goto(page, ctx.base_url <> "/#{owner}/#{repo}/labels", %{timeout: @nav_timeout})
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
    ensure_login(ctx, owner)
    page = ctx.page
    label_id = Gitea.label_id(ctx.client, owner, repo, label)

    Page.goto(page, ctx.base_url <> "/#{owner}/#{repo}/issues/#{number}", %{timeout: @nav_timeout})

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
    ensure_login(ctx, owner)
    page = ctx.page

    Page.goto(page, ctx.base_url <> "/#{owner}/#{repo}/issues/#{number}", %{timeout: @nav_timeout})

    Page.click(page, "#status-button")

    event =
      settle(
        fn -> Gitea.issue_closed_event(ctx.client, full_name, number) end,
        &(&1.state == "closed")
      )

    {:ok, [event]}
  end

  # --- session management ----------------------------------------------------

  defp ensure_login(ctx, user) do
    if Agent.get(ctx.session, & &1) != user do
      BrowserContext.clear_cookies(ctx.context)
      login(ctx.page, ctx.base_url, user, password_for(ctx, user))
      Agent.update(ctx.session, fn _ -> user end)
    end

    :ok
  end

  defp login(page, base_url, user, password) do
    Page.goto(page, base_url <> "/user/login", %{timeout: @nav_timeout})
    Page.fill(page, "input[name=user_name]", user)
    Page.fill(page, "input[name=password]", password)
    Page.press(page, "input[name=password]", "Enter")
    Page.wait_for_selector(page, "a[href='/#{user}']", %{timeout: @nav_timeout})
  end

  defp password_for(ctx, user) do
    if user == ctx.client.admin_user, do: ctx.client.admin_password, else: Gitea.user_password()
  end

  # --- helpers ---------------------------------------------------------------

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
