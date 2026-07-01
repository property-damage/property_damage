defmodule GiteaBench.WebhookAssertions do
  @moduledoc """
  The DR-030 judgment over the webhook-correlated set: exactly one delivered
  `issues` (closed) webhook per closed issue, split into its liveness and safety
  halves exactly as the `PropertyDamage.Await` contract prescribes.

  `CloseIssue.awaits/2` only *correlates* an inbound `IssueClosedWebhook` to the
  command that caused it (for failure localization). The judgment lives here, over
  this projection's own state — a per-issue delivery count folded from the webhook
  events, keyed by the client-chosen `{full_name, number}`:

    * **liveness** (`@poll_state`): after an issue is closed, its webhook must
      *eventually* arrive. The poller drains the `EventQueue` until the count for
      that issue reaches one, or fails as a poll-timeout localized (via the P5
      correlation) to the `CloseIssue` that dropped its delivery.
    * **safety** (`@trigger at: :teardown`): no issue may receive *more than one*
      delivery. Checked once on the settled final state, after all pollers
      finalize, so every arrived webhook is already counted.

  Together they assert "exactly one". This projection is deliberately separate
  from `GiteaBench.State` and used only by `GiteaBench.WebhookModel`: the shared
  API/UI/differential tests run no injector, so a liveness poller there would
  simply time out.
  """

  use PropertyDamage.Model.Projection

  alias GiteaBench.Events.{IssueClosed, IssueClosedWebhook}

  @impl true
  def init, do: %{webhooks: %{}}

  @impl true
  def apply(state, %IssueClosedWebhook{full_name: full_name, number: number}) do
    update_in(state, [:webhooks, {full_name, number}], &((&1 || 0) + 1))
  end

  def apply(state, _event), do: state

  # Liveness: the delivery for this specific closed issue must arrive.
  @poll_state after: IssueClosed, timeout: 10, interval: {200, :milliseconds}
  def webhook_delivered(_state, %IssueClosed{full_name: full_name, number: number}) do
    fn s -> Map.get(s.webhooks, {full_name, number}, 0) >= 1 end
  end

  # Safety: no issue may receive a duplicate delivery.
  @trigger at: :teardown
  def assert_at_most_one_webhook(state, _phase) do
    for {{full_name, number}, count} <- state.webhooks, count > 1 do
      PropertyDamage.fail!("issue received more than one close webhook",
        repo: full_name,
        issue: number,
        deliveries: count
      )
    end
  end
end
