defmodule GiteaBench.WebhookTest do
  @moduledoc """
  P9: exercising the P5 `awaits/2` correlation against a real SUT-driven event
  (a Gitea `issues` webhook).

  The fast describe proves the DR-030 judgment *bites* with no SUT: the safety
  `@trigger` raises on a duplicate delivery and the liveness `@poll_state`
  predicate is false until the delivery arrives. The tagged `:webhook_e2e`
  describe drives real closes against the dedicated `gitea-webhook` instance and
  asserts every close produces exactly one correlated webhook.
  """

  use ExUnit.Case, async: false

  alias GiteaBench.Events.{IssueClosed, IssueClosedWebhook}
  alias GiteaBench.WebhookAssertions

  describe "WebhookAssertions judgment (no SUT)" do
    test "folds each delivered webhook into a per-issue delivery count" do
      state =
        WebhookAssertions.init()
        |> WebhookAssertions.apply(%IssueClosedWebhook{full_name: "u0/r0", number: 1})
        |> WebhookAssertions.apply(%IssueClosedWebhook{full_name: "u0/r0", number: 1})
        |> WebhookAssertions.apply(%IssueClosedWebhook{full_name: "u0/r1", number: 2})

      assert state.webhooks == %{{"u0/r0", 1} => 2, {"u0/r1", 2} => 1}
    end

    test "safety bites: a duplicate delivery fails @trigger at: :teardown" do
      duplicate = %{webhooks: %{{"u0/r0", 1} => 2}}

      assert_raise PropertyDamage.AssertionFailed, fn ->
        WebhookAssertions.assert_at_most_one_webhook(duplicate, :teardown)
      end
    end

    test "safety passes on exactly one delivery per issue" do
      exactly_one = %{webhooks: %{{"u0/r0", 1} => 1, {"u0/r1", 2} => 1}}
      assert WebhookAssertions.assert_at_most_one_webhook(exactly_one, :teardown) == []
    end

    test "liveness predicate is false until the webhook arrives, then true" do
      closed = %IssueClosed{full_name: "u0/r0", number: 1, state: "closed"}
      pred = WebhookAssertions.webhook_delivered(%{}, closed)

      refute pred.(%{webhooks: %{}})
      assert pred.(%{webhooks: %{{"u0/r0", 1} => 1}})
    end
  end

  describe "end-to-end against the live gitea-webhook instance" do
    @describetag :webhook_e2e

    @tag timeout: 600_000
    test "closing issues delivers exactly one awaits-correlated webhook each" do
      assert {:ok, _stats} =
               PropertyDamage.run(
                 model: GiteaBench.WebhookModel,
                 adapter: GiteaBench.ApiAdapter,
                 adapter_config: %{
                   base_url: Application.fetch_env!(:gitea_bench, :webhook_url),
                   admin_user: Application.fetch_env!(:gitea_bench, :admin_user),
                   admin_password: Application.fetch_env!(:gitea_bench, :admin_password)
                 },
                 injector_adapters: [GiteaBench.WebhookInjector],
                 max_commands: 12,
                 max_runs: 3
               )
    end
  end
end
