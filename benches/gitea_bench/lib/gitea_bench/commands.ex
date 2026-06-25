defmodule GiteaBench.Commands do
  @moduledoc """
  Transport-agnostic command intents. Each command is a pure semantic operation;
  all state-dependent wiring (which repo to act on, the next unique name, which
  open issue to close) lives in `GiteaBench.Model`'s `when:`/`with:` options, not
  here. The same struct is handed to whichever adapter is executing, so a command
  carries no notion of API-vs-UI.

  Base generators are intentionally `nil`: every field a command needs is supplied
  by the model's `with:` override, derived from the generation-time projection
  state (the standard PropertyDamage pattern, e.g. `test/support/test_model.ex`).
  """

  import PropertyDamage.Generator, only: [merge_overrides: 2]

  defmodule CreateUser do
    @moduledoc "Create a (non-admin) user. login/email injected by the model."
    use PropertyDamage.Command

    @impl true
    def downstream_observables, do: [GiteaBench.Events.UserCreated]
    defstruct [:login, :email]

    @impl true
    def generator(overrides \\ %{}) do
      %{login: StreamData.constant(nil), email: StreamData.constant(nil)}
      |> merge_overrides(overrides)
      |> StreamData.fixed_map()
    end
  end

  defmodule CreateRepo do
    @moduledoc "Create a repo owned by an existing user. owner/name injected."
    use PropertyDamage.Command

    @impl true
    def downstream_observables, do: [GiteaBench.Events.RepoCreated]
    defstruct [:owner, :name]

    @impl true
    def generator(overrides \\ %{}) do
      %{owner: StreamData.constant(nil), name: StreamData.constant(nil)}
      |> merge_overrides(overrides)
      |> StreamData.fixed_map()
    end
  end

  defmodule CreateIssue do
    @moduledoc "Open an issue in an existing repo. repo is the `owner/name` ref."
    use PropertyDamage.Command

    @impl true
    def downstream_observables, do: [GiteaBench.Events.IssueCreated]
    defstruct [:repo, :title]

    @impl true
    def generator(overrides \\ %{}) do
      %{repo: StreamData.constant(nil), title: StreamData.constant(nil)}
      |> merge_overrides(overrides)
      |> StreamData.fixed_map()
    end
  end

  defmodule CreateLabel do
    @moduledoc "Define a label in an existing repo."
    use PropertyDamage.Command

    @impl true
    def downstream_observables, do: [GiteaBench.Events.LabelCreated]
    defstruct [:repo, :name, :color]

    @impl true
    def generator(overrides \\ %{}) do
      %{
        repo: StreamData.constant(nil),
        name: StreamData.constant(nil),
        color: StreamData.constant("#00aabb")
      }
      |> merge_overrides(overrides)
      |> StreamData.fixed_map()
    end
  end

  defmodule AddLabelToIssue do
    @moduledoc """
    Assign an existing label to an existing issue in the same repo. The three
    correlated values travel as one `assignment` field (`%{repo:, number:, label:}`)
    so the model can pick a coherent (repo, issue, label) triple in one shot.
    """
    use PropertyDamage.Command

    @impl true
    def downstream_observables, do: [GiteaBench.Events.LabelAssigned]
    defstruct [:assignment]

    @impl true
    def generator(overrides \\ %{}) do
      %{assignment: StreamData.constant(nil)}
      |> merge_overrides(overrides)
      |> StreamData.fixed_map()
    end
  end

  defmodule CloseIssue do
    @moduledoc "Close an open issue. target is `%{repo:, number:}` of an open issue."
    use PropertyDamage.Command

    @impl true
    def downstream_observables, do: [GiteaBench.Events.IssueClosed]
    defstruct [:target]

    @impl true
    def generator(overrides \\ %{}) do
      %{target: StreamData.constant(nil)}
      |> merge_overrides(overrides)
      |> StreamData.fixed_map()
    end
  end
end
