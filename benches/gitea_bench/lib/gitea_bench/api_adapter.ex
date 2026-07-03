defmodule GiteaBench.ApiAdapter do
  @moduledoc """
  Executes the model's intents against Gitea's REST API.

  Each `execute/3` performs the mutation via REST (acting as the relevant user)
  and then builds its event from a neutral observation read (`GiteaBench.Gitea`),
  so the events are directly comparable to the UI adapter's.

  Config (`opts`/`adapter_config`): `:base_url` (required), `:admin_user`,
  `:admin_password`.
  """

  use PropertyDamage.Adapter

  alias GiteaBench.Gitea

  alias GiteaBench.Commands.{
    AddLabelToIssue,
    CloseIssue,
    CreateIssue,
    CreateLabel,
    CreateRepo,
    CreateUser
  }

  @impl true
  def setup(config) do
    client = Gitea.new(config)
    :ok = Gitea.ensure_ready(client)
    :ok = Gitea.reset!(client)
    {:ok, %{client: client}}
  end

  @impl true
  def teardown(_ctx), do: :ok

  @impl true
  def execute(%CreateUser{login: login, email: email}, %{client: client}, _runtime) do
    with :ok <- Gitea.create_user(client, login, email) do
      {:ok, [Gitea.user_event(client, login)]}
    end
  end

  def execute(%CreateRepo{owner: owner, name: name}, %{client: client}, _runtime) do
    with :ok <- Gitea.create_repo(client, owner, name) do
      {:ok, [Gitea.repo_event(client, owner, name)]}
    end
  end

  def execute(%CreateIssue{repo: full_name, title: title}, %{client: client}, _runtime) do
    {owner, repo} = GiteaBench.split_full_name(full_name)

    with {:ok, number} <- Gitea.create_issue(client, owner, repo, title) do
      {:ok, [Gitea.issue_event(client, full_name, number, title)]}
    end
  end

  def execute(
        %CreateLabel{repo: full_name, name: name, color: color},
        %{client: client},
        _runtime
      ) do
    {owner, repo} = GiteaBench.split_full_name(full_name)

    with :ok <- Gitea.create_label(client, owner, repo, name, color) do
      {:ok, [Gitea.label_event(client, full_name, name)]}
    end
  end

  def execute(
        %AddLabelToIssue{assignment: %{repo: full_name, number: number, label: label}},
        %{
          client: client
        },
        _runtime
      ) do
    {owner, repo} = GiteaBench.split_full_name(full_name)

    with :ok <- Gitea.assign_label(client, owner, repo, number, label) do
      {:ok, [Gitea.label_assigned_event(client, full_name, number, label)]}
    end
  end

  def execute(
        %CloseIssue{target: %{repo: full_name, number: number}},
        %{client: client},
        _runtime
      ) do
    {owner, repo} = GiteaBench.split_full_name(full_name)

    with :ok <- Gitea.close_issue(client, owner, repo, number) do
      {:ok, [Gitea.issue_closed_event(client, full_name, number)]}
    end
  end
end
