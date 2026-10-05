defmodule GiteaBench.WebhookModel do
  @moduledoc """
  The P9 webhook demo model. It reuses `GiteaBench.Model`'s command chain,
  preconditions and parameterization (and the same `GiteaBench.State` projection
  and `GiteaBench.Simulator`), but weights `CloseIssue` up so runs actually close
  issues, and adds the injector-side surface the base model omits:

    * `check_projections/0` includes `GiteaBench.WebhookChecks` (the
      liveness + safety judgment over delivered webhooks);
    * `injectable_events/0` declares `IssueClosedWebhook`, which validation checks
      against the injector's `@emits`.

  Drive it with `injectors: [GiteaBench.WebhookInjector]` in the `targets:` entry against the
  dedicated gitea 1.24 instance (`:webhook_url`).
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

  alias GiteaBench.Model

  @impl true
  def commands do
    [
      {CreateUser, weight: 3, overrides: &Model.user_overrides/1},
      {CreateRepo, weight: 2, when: &Model.has_users?/1, overrides: &Model.repo_overrides/1},
      {CreateIssue, weight: 3, when: &Model.has_repos?/1, overrides: &Model.issue_overrides/1},
      {CreateLabel, weight: 1, when: &Model.has_repos?/1, overrides: &Model.label_overrides/1},
      {AddLabelToIssue,
       weight: 1, when: &Model.can_assign?/1, overrides: &Model.assign_overrides/1},
      {CloseIssue, weight: 3, when: &Model.has_open_issue?/1, overrides: &Model.close_overrides/1}
    ]
  end

  @impl true
  def command_sequence_projection, do: GiteaBench.State

  @impl true
  def check_projections, do: [GiteaBench.State, GiteaBench.WebhookChecks]

  @impl true
  def simulator, do: GiteaBench.Simulator

  @impl true
  def injectable_events, do: [GiteaBench.Events.IssueClosedWebhook]
end
