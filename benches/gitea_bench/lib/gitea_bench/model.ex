defmodule GiteaBench.Simulator do
  @moduledoc """
  Predicts one event per command during generation, before any forge is touched.

  The only non-trivial prediction is the issue number: Gitea numbers issues
  per-repo starting at 1, so on a freshly-reset instance the next number is the
  repo's current issue count plus one. That prediction is deterministic and
  identical on both instances, which is why the per-repo issue number is safe to
  use as a cross-transport link.
  """

  @behaviour PropertyDamage.Model.Simulator

  alias GiteaBench.Commands.{
    AddLabelToIssue,
    CloseIssue,
    CreateIssue,
    CreateLabel,
    CreateRepo,
    CreateUser
  }

  alias GiteaBench.Events.{
    IssueClosed,
    IssueCreated,
    LabelAssigned,
    LabelCreated,
    RepoCreated,
    UserCreated
  }

  @impl true
  def simulate(%CreateUser{login: login}, _state) do
    [%UserCreated{requested_login: login, login: login, id: nil}]
  end

  def simulate(%CreateRepo{owner: owner, name: name}, _state) do
    full_name = GiteaBench.full_name(owner, name)
    [%RepoCreated{owner: owner, requested_name: name, name: name, full_name: full_name, id: nil}]
  end

  def simulate(%CreateIssue{repo: full_name, title: title}, state) do
    number = (get_in(state, [:repos, full_name, :issue_count]) || 0) + 1

    [
      %IssueCreated{
        full_name: full_name,
        number: number,
        requested_title: title,
        title: title,
        id: nil
      }
    ]
  end

  def simulate(%CreateLabel{repo: full_name, name: name, color: color}, _state) do
    [%LabelCreated{full_name: full_name, requested_name: name, name: name, color: color, id: nil}]
  end

  def simulate(
        %AddLabelToIssue{assignment: %{repo: full_name, number: number, label: label}},
        state
      ) do
    current = get_in(state, [:repos, full_name, :issues, number, :labels]) || MapSet.new()
    predicted = current |> MapSet.put(label) |> MapSet.to_list() |> Enum.sort()

    [
      %LabelAssigned{
        full_name: full_name,
        number: number,
        requested_label: label,
        labels: predicted
      }
    ]
  end

  def simulate(%CloseIssue{target: %{repo: full_name, number: number}}, _state) do
    [%IssueClosed{full_name: full_name, number: number, state: "closed"}]
  end

  def simulate(_command, _state), do: []
end

defmodule GiteaBench.Model do
  @moduledoc """
  The single, transport-agnostic model. `commands/0` defines the dependency chain
  via `when:` preconditions and `with:` parameterization against `GiteaBench.State`;
  it never mentions API or UI. Creation names are derived from state counters so
  every create within a sequence is unique (no self-collision), while operations on
  existing entities draw from state so sequences interact (the same issue gets
  several labels, gets closed, etc.).
  """

  @behaviour PropertyDamage.Model

  alias GiteaBench.Commands.{
    AddLabelToIssue,
    CloseIssue,
    CreateIssue,
    CreateLabel,
    CreateRepo,
    CreateUser
  }

  @impl true
  def commands do
    [
      {CreateUser, weight: 3, with: &user_overrides/1},
      {CreateRepo, weight: 3, when: &has_users?/1, with: &repo_overrides/1},
      {CreateIssue, weight: 3, when: &has_repos?/1, with: &issue_overrides/1},
      {CreateLabel, weight: 2, when: &has_repos?/1, with: &label_overrides/1},
      {AddLabelToIssue, weight: 2, when: &can_assign?/1, with: &assign_overrides/1},
      {CloseIssue, weight: 1, when: &has_open_issue?/1, with: &close_overrides/1}
    ]
  end

  @impl true
  def command_sequence_projection, do: GiteaBench.State

  @impl true
  def assertion_projections, do: [GiteaBench.State]

  @impl true
  def simulator, do: GiteaBench.Simulator

  # --- preconditions ---------------------------------------------------------

  def has_users?(state), do: map_size(state.users) > 0
  def has_repos?(state), do: map_size(state.repos) > 0
  def can_assign?(state), do: assignments(state) != []
  def has_open_issue?(state), do: open_targets(state) != []

  # --- parameterization ------------------------------------------------------

  def user_overrides(state) do
    login = "u#{map_size(state.users)}"
    %{login: StreamData.constant(login), email: StreamData.constant(login <> "@pd.local")}
  end

  def repo_overrides(state) do
    %{
      owner: StreamData.member_of(Map.keys(state.users)),
      name: StreamData.constant("r#{map_size(state.repos)}")
    }
  end

  def issue_overrides(state) do
    %{
      repo: StreamData.member_of(Map.keys(state.repos)),
      title: StreamData.member_of(["bug", "feature", "docs"])
    }
  end

  def label_overrides(state) do
    %{
      repo: StreamData.member_of(Map.keys(state.repos)),
      name: StreamData.constant("l#{total_labels(state)}")
    }
  end

  def assign_overrides(state) do
    %{assignment: StreamData.member_of(assignments(state))}
  end

  def close_overrides(state) do
    %{target: StreamData.member_of(open_targets(state))}
  end

  # --- derived selections ----------------------------------------------------

  defp total_labels(state) do
    Enum.reduce(state.repos, 0, fn {_full_name, repo}, acc -> acc + MapSet.size(repo.labels) end)
  end

  # Every coherent (repo, issue, label) triple: a repo that has at least one issue
  # and one label, crossed over its issues and labels.
  defp assignments(state) do
    for {full_name, repo} <- state.repos,
        repo.issues != %{},
        repo.labels != MapSet.new(),
        {number, _issue} <- repo.issues,
        label <- MapSet.to_list(repo.labels) do
      %{repo: full_name, number: number, label: label}
    end
  end

  defp open_targets(state) do
    for {full_name, repo} <- state.repos,
        {number, issue} <- repo.issues,
        issue.state == :open do
      %{repo: full_name, number: number}
    end
  end
end
