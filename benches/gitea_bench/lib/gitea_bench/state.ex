defmodule GiteaBench.State do
  @moduledoc """
  The model's view of the forge, doubling as the assertion projection.

  During generation it is fed the simulator's predicted events so `when:`/`with:`
  can pick coherent targets; during execution it is fed the adapters' real events
  and the `@trigger` assertions check fidelity. Because every field it keys on
  (login, `owner/name`, per-repo issue number, label names) is client-chosen and
  identical across transports, the same projection logic serves both phases and
  both adapters.
  """

  use PropertyDamage.Model.Projection

  alias GiteaBench.Events.{
    IssueClosed,
    IssueCreated,
    LabelAssigned,
    LabelCreated,
    RepoCreated,
    UserCreated
  }

  # DR-026 invariant catalog: the properties the assertions below uphold.
  @invariant id: :user_login_faithful,
             description: "The SUT creates the user under the requested login"
  @invariant id: :repo_name_faithful,
             description: "The SUT creates the repo under the requested name"
  @invariant id: :issue_title_faithful,
             description: "The SUT stores the issue under the requested title"
  @invariant id: :label_name_faithful,
             description: "The SUT creates the label under the requested name"
  @invariant id: :assigned_label_defined,
             description: "A label assigned to an issue was first defined in that repo"
  @invariant id: :assigned_label_observed,
             description: "After assignment, the SUT actually shows the label on the issue"
  @invariant id: :issue_closed_observed,
             description: "After closing, the SUT actually reports the issue as closed"
  @invariant id: :assigned_labels_subset,
             description: "Every issue's labels are a subset of its repo's labels"

  @impl true
  def init, do: %{users: %{}, repos: %{}}

  @impl true
  def apply(state, %UserCreated{login: login}) do
    put_in(state, [:users, login], %{})
  end

  def apply(state, %RepoCreated{owner: owner, name: name, full_name: full_name}) do
    repo = %{owner: owner, name: name, labels: MapSet.new(), issues: %{}, issue_count: 0}
    put_in(state, [:repos, full_name], repo)
  end

  def apply(state, %IssueCreated{full_name: full_name, number: number, title: title}) do
    state
    |> put_in([:repos, full_name, :issues, number], %{
      title: title,
      labels: MapSet.new(),
      state: :open
    })
    |> update_in([:repos, full_name, :issue_count], &(&1 + 1))
  end

  def apply(state, %LabelCreated{full_name: full_name, name: name}) do
    update_in(state, [:repos, full_name, :labels], &MapSet.put(&1, name))
  end

  def apply(state, %LabelAssigned{full_name: full_name, number: number, requested_label: label}) do
    update_in(state, [:repos, full_name, :issues, number, :labels], &MapSet.put(&1, label))
  end

  def apply(state, %IssueClosed{full_name: full_name, number: number}) do
    put_in(state, [:repos, full_name, :issues, number, :state], :closed)
  end

  def apply(state, _event), do: state

  # --- SUT-fidelity assertions (non-vacuous even on a single transport) -------

  @trigger every: UserCreated, validates: :user_login_faithful
  def assert_user_login(_state, %UserCreated{login: login, requested_login: requested}) do
    if login != requested do
      PropertyDamage.fail!("user created under wrong login",
        requested: requested,
        observed: login
      )
    end
  end

  @trigger every: RepoCreated, validates: :repo_name_faithful
  def assert_repo_name(_state, %RepoCreated{name: name, requested_name: requested}) do
    if name != requested do
      PropertyDamage.fail!("repo created under wrong name",
        requested: requested,
        observed: name
      )
    end
  end

  @trigger every: IssueCreated, validates: :issue_title_faithful
  def assert_issue_title(_state, %IssueCreated{title: title, requested_title: requested}) do
    if title != requested do
      PropertyDamage.fail!("issue stored under wrong title",
        requested: requested,
        observed: title
      )
    end
  end

  @trigger every: LabelCreated, validates: :label_name_faithful
  def assert_label_name(_state, %LabelCreated{name: name, requested_name: requested}) do
    if name != requested do
      PropertyDamage.fail!("label created under wrong name",
        requested: requested,
        observed: name
      )
    end
  end

  @trigger every: LabelAssigned, validates: :assigned_label_defined
  def assert_assigned_label_defined(state, %LabelAssigned{
        full_name: full_name,
        requested_label: label
      }) do
    labels = get_in(state, [:repos, full_name, :labels]) || MapSet.new()

    unless MapSet.member?(labels, label) do
      PropertyDamage.fail!("assigned a label that was never defined in the repo",
        repo: full_name,
        label: label,
        defined: MapSet.to_list(labels)
      )
    end
  end

  @trigger every: LabelAssigned, validates: :assigned_label_observed
  def assert_assigned_label_observed(_state, %LabelAssigned{
        requested_label: label,
        labels: observed
      }) do
    unless label in (observed || []) do
      PropertyDamage.fail!("SUT does not show the assigned label on the issue",
        requested: label,
        observed: observed
      )
    end
  end

  @trigger every: IssueClosed, validates: :issue_closed_observed
  def assert_issue_closed_observed(_state, %IssueClosed{state: state}) do
    unless state == "closed" do
      PropertyDamage.fail!("issue not reported closed by the SUT", observed_state: state)
    end
  end

  # --- Whole-run structural consistency --------------------------------------

  @trigger at: :teardown, validates: :assigned_labels_subset
  def assert_labels_subset(state, _phase) do
    Enum.each(state.repos, fn {full_name, repo} ->
      Enum.each(repo.issues, fn {number, issue} ->
        unless MapSet.subset?(issue.labels, repo.labels) do
          PropertyDamage.fail!("issue carries a label not defined in its repo",
            repo: full_name,
            issue: number,
            issue_labels: MapSet.to_list(issue.labels),
            repo_labels: MapSet.to_list(repo.labels)
          )
        end
      end)
    end)
  end
end
