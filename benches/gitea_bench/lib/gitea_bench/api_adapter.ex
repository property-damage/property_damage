defmodule GiteaBench.ApiAdapter do
  @moduledoc """
  Executes the model's intents against Gitea's REST API.

  Each `execute/3` performs the mutation via REST (acting as the relevant user)
  and then builds its event from a neutral observation read (`GiteaBench.Gitea`),
  so the events are directly comparable to the UI adapter's.

  Config (`config:` in the `targets:` entry): `:base_url` (required), `:admin_user`,
  `:admin_password`, and `:login_password`, the password the `Login` setup
  command authenticates the admin with (default: `:admin_password`; `setup/1`
  always resets the forge with `:admin_password`).
  """

  use PropertyDamage.Adapter

  alias GiteaBench.Events.SessionOpened
  alias GiteaBench.{Gitea, WebhookInjector}

  alias GiteaBench.Commands.{
    AddLabelToIssue,
    CloseIssue,
    CreateIssue,
    CreateLabel,
    CreateRepo,
    CreateUser,
    Login
  }

  @impl true
  def setup(config) do
    client = Gitea.new(config)
    :ok = Gitea.ensure_ready(client)
    :ok = Gitea.reset!(client)
    {:ok, %{client: client, login_password: login_password(config, client)}}
  end

  @impl true
  def teardown(_ctx), do: :ok

  @impl true
  def execute(command, ctx, runtime) do
    # A webhook Gitea delivers while this command runs is logged under its step.
    WebhookInjector.attach(runtime)
    perform(command, ctx)
  end

  defp perform(%Login{}, %{client: client, login_password: password}) do
    case Gitea.verify_login(client, client.admin_user, password) do
      :ok -> {:ok, [%SessionOpened{user: client.admin_user}]}
      {:error, status} -> {:error, {:login_failed, status}}
    end
  end

  defp perform(%CreateUser{login: login, email: email}, %{client: client}) do
    with :ok <- Gitea.create_user(client, login, email) do
      {:ok, [Gitea.user_event(client, login)]}
    end
  end

  defp perform(%CreateRepo{owner: owner, name: name}, %{client: client}) do
    with :ok <- Gitea.create_repo(client, owner, name) do
      {:ok, [Gitea.repo_event(client, owner, name)]}
    end
  end

  defp perform(%CreateIssue{repo: full_name, title: title}, %{client: client}) do
    {owner, repo} = GiteaBench.split_full_name(full_name)

    with {:ok, number} <- Gitea.create_issue(client, owner, repo, title) do
      {:ok, [Gitea.issue_event(client, full_name, number, title)]}
    end
  end

  defp perform(
         %CreateLabel{repo: full_name, name: name, color: color},
         %{client: client}
       ) do
    {owner, repo} = GiteaBench.split_full_name(full_name)

    with :ok <- Gitea.create_label(client, owner, repo, name, color) do
      {:ok, [Gitea.label_event(client, full_name, name)]}
    end
  end

  defp perform(
         %AddLabelToIssue{assignment: %{repo: full_name, number: number, label: label}},
         %{
           client: client
         }
       ) do
    {owner, repo} = GiteaBench.split_full_name(full_name)

    with :ok <- Gitea.assign_label(client, owner, repo, number, label) do
      {:ok, [Gitea.label_assigned_event(client, full_name, number, label)]}
    end
  end

  defp perform(
         %CloseIssue{target: %{repo: full_name, number: number}},
         %{client: client}
       ) do
    {owner, repo} = GiteaBench.split_full_name(full_name)

    with :ok <- Gitea.close_issue(client, owner, repo, number) do
      {:ok, [Gitea.issue_closed_event(client, full_name, number)]}
    end
  end

  defp login_password(config, client),
    do: Map.get(config, :login_password, client.admin_password)
end
