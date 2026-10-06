defmodule GiteaBench.Commands do
  @moduledoc """
  Transport-agnostic command intents. Each command is a pure semantic operation;
  all state-dependent wiring (which repo to act on, the next unique name, which
  open issue to close) lives in `GiteaBench.Model`'s `when:`/`overrides:` options, not
  here. The same struct is handed to whichever adapter is executing, so a command
  carries no notion of API-vs-UI.

  Base generators are intentionally `nil`: every field a command needs is supplied
  by the model's `overrides:` option, derived from the generation-time projection
  state (the standard PropertyDamage pattern, e.g. `test/support/test_model.ex`).
  """

  import PropertyDamage.Generator, only: [merge_overrides: 2]

  defmodule Login do
    @moduledoc """
    Open the admin's session on the forge. The model's only setup command
    (`GiteaBench.Model.setup_each/0`): every run, in every target, starts with
    it. Each transport logs in its own way: the API adapter verifies the
    credentials with one authenticated request, the UI adapter logs the admin
    in through the browser and keeps the session for the admin's later actions.
    """
    use PropertyDamage.Command, observables: [GiteaBench.Events.SessionOpened]

    defstruct []

    @impl true
    def generator(overrides \\ %{}) do
      %{}
      |> merge_overrides(overrides)
      |> StreamData.fixed_map()
    end
  end

  defmodule CreateUser do
    @moduledoc "Create a (non-admin) user. login/email injected by the model."
    use PropertyDamage.Command, observables: [GiteaBench.Events.UserCreated]

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
    use PropertyDamage.Command, observables: [GiteaBench.Events.RepoCreated]

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
    use PropertyDamage.Command, observables: [GiteaBench.Events.IssueCreated]

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
    use PropertyDamage.Command, observables: [GiteaBench.Events.LabelCreated]

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
    use PropertyDamage.Command, observables: [GiteaBench.Events.LabelAssigned]

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
    use PropertyDamage.Command, observables: [GiteaBench.Events.IssueClosed]

    alias GiteaBench.Events.IssueClosedWebhook

    defstruct [:target]

    @impl true
    def generator(overrides \\ %{}) do
      %{target: StreamData.constant(nil)}
      |> merge_overrides(overrides)
      |> StreamData.fixed_map()
    end

    # DR-030 pure correlation: claim the `issues` (closed) webhook the SUT
    # delivers for *this* issue, keyed by the client-chosen {full_name, number}.
    # This attributes the delivery to this command's index (failure localization);
    # the "exactly one webhook" judgment lives in GiteaBench.WebhookChecks.
    @impl true
    def awaits(_state, %__MODULE__{target: %{repo: full_name, number: number}}) do
      [
        %PropertyDamage.Await{
          match: &match?(%IssueClosedWebhook{full_name: ^full_name, number: ^number}, &1)
        }
      ]
    end
  end
end
