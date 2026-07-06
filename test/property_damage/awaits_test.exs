defmodule PropertyDamage.AwaitsTest do
  @moduledoc """
  P5 (DR-030, amended): `Command.awaits/2` is **pure correlation**. When an
  injector event satisfies a command's `%Await{match}` predicate, the framework
  attributes that event to the declaring command's `command_index` (instead of
  the ambient `nil`), persistently for the rest of the run. Judgment over the
  correlated set lives in projections:

    * **liveness** via a `@poll_state` over the correlated set;
    * **safety / cardinality** via a `@trigger`/`@invariant` over it.

  There is no bespoke await loop: `@poll_state`'s finalize drain already awaits
  the internal `EventQueue`. A liveness poll-timeout reports at the *triggering*
  command's index so the shrinker keeps locality.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias PropertyDamage.{Await, EventQueue, Executor, Failure, Sequence}

  # --- Events -----------------------------------------------------------------

  defmodule IssueCloseRequested, do: defstruct([:issue_id])
  defmodule IssueClosedWebhook, do: defstruct([:issue_id])

  # --- Injector (tag for pushed events) ---------------------------------------

  defmodule WebhookInjector do
    use PropertyDamage.Adapter.Injector
    @emits [IssueClosedWebhook]
    @impl true
    def setup(config), do: {:ok, config}
    @impl true
    def teardown(_context), do: :ok
    @impl true
    def to_event(payload), do: {:ok, payload}
  end

  # --- Commands ---------------------------------------------------------------

  defmodule CloseIssue do
    use PropertyDamage.Command
    defstruct [:issue_id]

    @impl true
    def generator(overrides \\ %{}) do
      %{issue_id: StreamData.constant("i1")}
      |> PropertyDamage.Generator.merge_overrides(overrides)
      |> StreamData.fixed_map()
    end

    # Correlate the webhook for *this* issue back to this command.
    @impl true
    def awaits(_state, %__MODULE__{issue_id: id}) do
      [
        %Await{
          match: fn
            %IssueClosedWebhook{issue_id: ^id} -> true
            _ -> false
          end
        }
      ]
    end
  end

  # A command whose await matches ANY closed-webhook (used for overlap).
  defmodule CloseAnyIssue do
    use PropertyDamage.Command
    defstruct [:issue_id]

    @impl true
    def generator(overrides \\ %{}) do
      %{issue_id: StreamData.constant("i2")}
      |> PropertyDamage.Generator.merge_overrides(overrides)
      |> StreamData.fixed_map()
    end

    @impl true
    def awaits(_state, %__MODULE__{}) do
      [%Await{match: &match?(%IssueClosedWebhook{}, &1)}]
    end
  end

  # --- Projection -------------------------------------------------------------

  defmodule IssueProjection do
    use PropertyDamage.Model.Projection

    @impl true
    def init, do: %{closed: %{}, webhooks: %{}}

    @impl true
    def apply(state, %IssueCloseRequested{issue_id: id}),
      do: put_in(state.closed[id], true)

    def apply(state, %IssueClosedWebhook{issue_id: id}),
      do: update_in(state, [:webhooks, id], fn n -> (n || 0) + 1 end)

    def apply(state, _), do: state

    # Liveness: the closing webhook for the issue eventually correlates.
    @poll_state after: IssueCloseRequested,
                timeout: {200, :milliseconds},
                interval: {10, :milliseconds}
    def webhook_eventually_arrives(_state, %IssueCloseRequested{issue_id: id}) do
      fn s -> (s.webhooks[id] || 0) >= 1 end
    end

    # Safety: at most one closing webhook per issue.
    @trigger every: IssueClosedWebhook
    def assert_at_most_one_webhook(state, _event) do
      unless Enum.all?(state.webhooks, fn {_id, n} -> n <= 1 end) do
        PropertyDamage.fail!("more than one closing webhook for an issue",
          webhooks: state.webhooks
        )
      end
    end
  end

  defmodule IssueModel do
    @behaviour PropertyDamage.Model
    @impl true
    def commands, do: [CloseIssue]
    @impl true
    def command_sequence_projection, do: IssueProjection
    @impl true
    def assertion_projections, do: [IssueProjection]
  end

  # --- Adapters ---------------------------------------------------------------

  # Closes the issue synchronously via the "API"; the webhook arrives out of band.
  defmodule ApiAdapter do
    use PropertyDamage.Adapter
    @impl true
    def setup(config), do: {:ok, config}
    @impl true
    def teardown(_context), do: :ok
    @impl true
    def execute(%CloseIssue{issue_id: id}, _ctx, _runtime),
      do: {:ok, [%IssueCloseRequested{issue_id: id}]}

    def execute(%CloseAnyIssue{issue_id: id}, _ctx, _runtime),
      do: {:ok, [%IssueCloseRequested{issue_id: id}]}
  end

  defp run(seq, opts) do
    {:ok, queue} = EventQueue.start_link()

    try do
      {:ok, result} =
        Executor.run(
          Sequence.linear(seq),
          IssueModel,
          ApiAdapter,
          [event_queue: queue] ++ opts.(queue)
        )

      result
    after
      EventQueue.stop(queue)
    end
  end

  describe "correlation / attribution" do
    test "an injector event matching awaits/2 is attributed to the awaiting command's index" do
      result =
        run([%CloseIssue{issue_id: "i1"}], fn queue ->
          EventQueue.push(queue, WebhookInjector, %IssueClosedWebhook{issue_id: "i1"})
          []
        end)

      entry = Enum.find(result.event_log, &match?(%IssueClosedWebhook{}, &1.event))
      assert entry, "expected the webhook to be folded into the event log"

      # RED before P5 wiring: injector events fold with command_index: nil.
      assert entry.command_index == 0,
             "expected the webhook attributed to CloseIssue (index 0), got #{inspect(entry.command_index)}"
    end

    test "an unmatched injector event still folds as ambient (command_index: nil)" do
      result =
        run([%CloseIssue{issue_id: "i1"}], fn queue ->
          # Different issue: no command's awaits matches it.
          EventQueue.push(queue, WebhookInjector, %IssueClosedWebhook{issue_id: "other"})
          []
        end)

      entry =
        Enum.find(result.event_log, &match?(%IssueClosedWebhook{issue_id: "other"}, &1.event))

      assert entry
      assert entry.command_index == nil
    end
  end

  describe "safety via @trigger on the correlated set" do
    test "a duplicate correlated webhook trips the cardinality assertion" do
      result =
        run([%CloseIssue{issue_id: "i1"}], fn queue ->
          EventQueue.push(queue, WebhookInjector, %IssueClosedWebhook{issue_id: "i1"})
          EventQueue.push(queue, WebhookInjector, %IssueClosedWebhook{issue_id: "i1"})
          []
        end)

      refute result.success

      assert %Failure{
               type: %Failure.Assertion{kind: :assertion_failed, name: :at_most_one_webhook}
             } =
               result.failure_reason

      # Both deliveries are attributed to the command that owns the issue.
      indices =
        result.event_log
        |> Enum.filter(&match?(%IssueClosedWebhook{}, &1.event))
        |> Enum.map(& &1.command_index)

      assert indices == [0, 0],
             "expected both webhooks attributed to CloseIssue (index 0), got #{inspect(indices)}"
    end
  end

  # Safety-only projection (no @poll_state) so the inline DR-025 async check is
  # the only thing that can halt the run — no poller timing to interfere.
  defmodule SafetyOnlyProjection do
    use PropertyDamage.Model.Projection

    @impl true
    def init, do: %{webhooks: %{}}

    @impl true
    def apply(state, %IssueClosedWebhook{issue_id: id}),
      do: update_in(state, [:webhooks, id], fn n -> (n || 0) + 1 end)

    def apply(state, _), do: state

    @trigger every: IssueClosedWebhook
    def assert_at_most_one_webhook(state, _event) do
      unless Enum.all?(state.webhooks, fn {_id, n} -> n <= 1 end) do
        PropertyDamage.fail!("more than one closing webhook for an issue",
          webhooks: state.webhooks
        )
      end
    end
  end

  defmodule LaterDeliveryModel do
    @behaviour PropertyDamage.Model
    @impl true
    def commands, do: [CloseIssue]
    @impl true
    def command_sequence_projection, do: SafetyOnlyProjection
    @impl true
    def assertion_projections, do: [SafetyOnlyProjection]
  end

  # A later, unrelated command whose adapter delivers the duplicate webhooks for
  # issue "i1", so they are drained (and the assertion trips) during THIS
  # command's pipeline, not the awaiting command's.
  defmodule DeliverWebhooks do
    use PropertyDamage.Command
    defstruct []

    @impl true
    def generator(_overrides \\ %{}), do: StreamData.constant(%{})
  end

  defmodule LaterDeliveryAdapter do
    use PropertyDamage.Adapter
    @impl true
    def setup(config), do: {:ok, config}
    @impl true
    def teardown(_context), do: :ok

    @impl true
    def execute(%CloseIssue{issue_id: id}, _ctx, _runtime),
      do: {:ok, [%IssueCloseRequested{issue_id: id}]}

    def execute(%DeliverWebhooks{}, ctx, _runtime) do
      EventQueue.push(ctx.event_queue, WebhookInjector, %IssueClosedWebhook{issue_id: "i1"})
      EventQueue.push(ctx.event_queue, WebhookInjector, %IssueClosedWebhook{issue_id: "i1"})
      {:ok, []}
    end
  end

  describe "attribution of an async every: failure to an earlier command (DR-025)" do
    test "a later command's drain trips the assertion but the failure names the awaiting command" do
      {:ok, queue} = EventQueue.start_link()
      seq = Sequence.linear([%CloseIssue{issue_id: "i1"}, %DeliverWebhooks{}])

      {:ok, result} =
        Executor.run(seq, LaterDeliveryModel, LaterDeliveryAdapter,
          event_queue: queue,
          adapter_config: %{event_queue: queue}
        )

      EventQueue.stop(queue)

      refute result.success

      assert %Failure{
               type: %Failure.Assertion{kind: :assertion_failed, name: :at_most_one_webhook}
             } = result.failure_reason

      # The offending webhooks are correlated to CloseIssue (index 0); the
      # assertion tripped while DeliverWebhooks (index 1) was draining them.
      # DR-025 command attribution must name the owning command, not the current.
      indices =
        result.event_log
        |> Enum.filter(&match?(%IssueClosedWebhook{}, &1.event))
        |> Enum.map(& &1.command_index)

      assert indices == [0, 0]
      assert result.failed_at_index == 0
    end
  end

  # No-assertion projection so the overlap scenario exercises pure attribution
  # (no pollers / triggers to interfere).
  defmodule PlainProjection do
    use PropertyDamage.Model.Projection
    @impl true
    def init, do: %{}
    @impl true
    def apply(state, _), do: state
  end

  defmodule OverlapModel do
    @behaviour PropertyDamage.Model
    @impl true
    def commands, do: [CloseIssue, CloseAnyIssue]
    @impl true
    def command_sequence_projection, do: PlainProjection
    @impl true
    def assertion_projections, do: []
  end

  # The second command delivers the webhook for issue "i1" once BOTH commands'
  # awaits are registered, forcing an overlap (CloseIssue's i1 matcher and
  # CloseAnyIssue's match-all both accept it) at a single drain.
  defmodule OverlapAdapter do
    use PropertyDamage.Adapter
    @impl true
    def setup(config), do: {:ok, config}
    @impl true
    def teardown(_context), do: :ok

    @impl true
    def execute(%CloseIssue{issue_id: id}, _ctx, _runtime),
      do: {:ok, [%IssueCloseRequested{issue_id: id}]}

    def execute(%CloseAnyIssue{}, ctx, _runtime) do
      EventQueue.push(ctx.event_queue, WebhookInjector, %IssueClosedWebhook{issue_id: "i1"})
      {:ok, [%IssueCloseRequested{issue_id: "i2"}]}
    end
  end

  describe "multiplicity: first-registered tie-break + overlap diagnostic" do
    test "an event matching several awaits is attributed to the first-registered, with a diagnostic" do
      {:ok, queue} = EventQueue.start_link()
      seq = Sequence.linear([%CloseIssue{issue_id: "i1"}, %CloseAnyIssue{issue_id: "i2"}])

      {result, log} =
        with_log(fn ->
          {:ok, r} =
            Executor.run(seq, OverlapModel, OverlapAdapter,
              event_queue: queue,
              adapter_config: %{event_queue: queue}
            )

          r
        end)

      EventQueue.stop(queue)

      entry = Enum.find(result.event_log, &match?(%IssueClosedWebhook{}, &1.event))
      assert entry

      # CloseIssue (index 0) registered before CloseAnyIssue (index 1); the
      # first-registered claims the overlapping event.
      assert entry.command_index == 0,
             "expected first-registered (index 0) to win, got #{inspect(entry.command_index)}"

      assert log =~ "Await overlap"
    end
  end

  describe "liveness via @poll_state on the correlated set" do
    test "a never-arriving awaited event times out at the awaiting command's index" do
      result = run([%CloseIssue{issue_id: "i1"}], fn _queue -> [] end)

      refute result.success

      assert %Failure{type: %Failure.Assertion{kind: :poll_timeout, detail: info}} =
               result.failure_reason

      assert info.triggered_by.assertion_name == :webhook_eventually_arrives

      # RED before P5: poll timeouts report failed_at_index: nil, losing the
      # link to the command whose liveness window opened.
      assert result.failed_at_index == 0,
             "expected the poll-timeout attributed to CloseIssue (index 0), got #{inspect(result.failed_at_index)}"
    end
  end

  # The awaits/2 <-> simulate/2 contract: a command's simulator predicts the
  # event its awaits/2 will correlate live. In the symbolic phase there is no
  # injector queue; a simulated awaited event folds as the command's own output,
  # so its projection state must match the live correlated run.
  defmodule IssueSimulator do
    @behaviour PropertyDamage.Model.Simulator
    @impl true
    def simulate(%CloseIssue{issue_id: id}, _state) do
      [%IssueCloseRequested{issue_id: id}, %IssueClosedWebhook{issue_id: id}]
    end

    def simulate(_command, _state), do: []
  end

  describe "simulator parity (awaits/2 <-> simulate/2 contract)" do
    test "a simulated awaited event folds to the same projection state as a live correlated one" do
      cmd = %CloseIssue{issue_id: "i1"}

      live =
        run([cmd], fn queue ->
          EventQueue.push(queue, WebhookInjector, %IssueClosedWebhook{issue_id: "i1"})
          []
        end)

      live_webhooks = live.projections[IssueProjection].webhooks

      simulated_webhooks =
        cmd
        |> IssueSimulator.simulate(IssueProjection.init())
        |> Enum.reduce(IssueProjection.init(), &IssueProjection.apply(&2, &1))
        |> Map.fetch!(:webhooks)

      assert live_webhooks == %{"i1" => 1}
      assert simulated_webhooks == live_webhooks
    end
  end
end
