defmodule GiteaBench.WebhookModel do
  @moduledoc """
  The P9 webhook demo model. It reuses `GiteaBench.Model`'s command chain,
  preconditions and parameterization (and the same `GiteaBench.State` projection
  and `GiteaBench.Simulator`), but weights `CloseIssue` up so runs actually close
  issues, and adds the injector-side surface the base model omits:

    * `assertion_projections/0` includes `GiteaBench.WebhookAssertions` (the
      liveness + safety judgment over delivered webhooks);
    * `injectable_events/0` declares `IssueClosedWebhook`, which validation checks
      against the injector's `@emits`.

  Drive it with `injector_adapters: [GiteaBench.WebhookInjector]` against the
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
      {CreateUser, weight: 3, with: &Model.user_overrides/1},
      {CreateRepo, weight: 2, when: &Model.has_users?/1, with: &Model.repo_overrides/1},
      {CreateIssue, weight: 3, when: &Model.has_repos?/1, with: &Model.issue_overrides/1},
      {CreateLabel, weight: 1, when: &Model.has_repos?/1, with: &Model.label_overrides/1},
      {AddLabelToIssue, weight: 1, when: &Model.can_assign?/1, with: &Model.assign_overrides/1},
      {CloseIssue, weight: 3, when: &Model.has_open_issue?/1, with: &Model.close_overrides/1}
    ]
  end

  @impl true
  def command_sequence_projection, do: GiteaBench.State

  @impl true
  def assertion_projections, do: [GiteaBench.State, GiteaBench.WebhookAssertions]

  @impl true
  def simulator, do: GiteaBench.Simulator

  @impl true
  def injectable_events, do: [GiteaBench.Events.IssueClosedWebhook]
end
