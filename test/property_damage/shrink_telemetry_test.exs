defmodule PropertyDamage.ShrinkTelemetryTest do
  # The shrinker emits `[:property_damage, :shrink, :start | :iteration | :stop]`
  # events: one start, one iteration per candidate and one stop that totals the
  # candidates' time and the time their adapters spent in setup/1 and teardown/1.
  # Handlers are global, so this file runs alone.
  use ExUnit.Case, async: false

  alias PropertyDamage.Shrinker
  alias PropertyDamage.Shrinker.Config
  alias PropertyDamage.Test.Compare.PayAdapter
  alias PropertyDamage.Test.FakeOracle
  alias PropertyDamage.Test.ReferenceReport, as: R
  alias PropertyDamage.Test.ShrinkOracle, as: O

  @events [
    [:property_damage, :shrink, :start],
    [:property_damage, :shrink, :iteration],
    [:property_damage, :shrink, :stop]
  ]

  # A pay adapter whose setup/1 and teardown/1 each take a known time.
  defmodule SlowAdapter do
    @moduledoc false
    use PropertyDamage.Adapter

    @impl true
    def setup(config) do
      Process.sleep(20)
      PayAdapter.setup(config)
    end

    @impl true
    def teardown(ctx) do
      Process.sleep(10)
      PayAdapter.teardown(ctx)
    end

    @impl true
    def execute(command, ctx, runtime), do: PayAdapter.execute(command, ctx, runtime)
  end

  # Sends every shrink event this test's process emits to the process.
  defp attach do
    id = {__MODULE__, make_ref()}
    parent = self()

    :telemetry.attach_many(id, @events, &__MODULE__.forward/4, parent)

    on_exit(fn -> :telemetry.detach(id) end)
  end

  @doc false
  def forward(event, measurements, metadata, parent),
    do: send(parent, {:shrink_event, event, measurements, metadata})

  defp events do
    receive do
      {:shrink_event, event, measurements, metadata} ->
        [{event, measurements, metadata} | events()]
    after
      0 -> []
    end
  end

  defp original do
    [
      %O.Deposit{account: :alice, amount: 40},
      %O.Deposit{account: :bob, amount: 5},
      %O.Withdraw{account: :alice, amount: 7},
      %O.Deposit{account: :bob, amount: 9},
      %O.Withdraw{account: :alice, amount: 3}
    ]
  end

  # Fails at the root of the first withdrawal that follows a deposit.
  defp rule(plan, _epoch) do
    case O.withdraw_after_deposit(plan.commands) do
      nil -> :passed
      root -> {:failed, root}
    end
  end

  defp shrink(oracle) do
    Shrinker.shrink(O.sequence(original(), [%O.Open{account: :alice}]),
      failed_at_index: 4,
      failure_reason: O.failure(),
      variant_index: 0,
      model: O.Model,
      targets: O.targets(),
      oracle: oracle,
      config: Config.new(shrink_arguments: false)
    )
  end

  describe "with an in-memory oracle" do
    setup do
      attach()
      {oracle, log} = FakeOracle.start(&rule/2, O.signature())
      %{oracle: oracle, log: log}
    end

    test "emits one start event with the original length", %{oracle: oracle} do
      shrink(oracle)

      assert [{_, %{system_time: _}, %{original_length: 5}}] =
               Enum.filter(events(), &match?({[_, _, :start], _, _}, &1))
    end

    test "emits one iteration event for each oracle call", %{oracle: oracle, log: log} do
      result = shrink(oracle)
      iterations = for {[_, _, :iteration], m, md} <- events(), do: {m, md}

      assert length(iterations) == length(FakeOracle.calls(log))
      assert length(iterations) == result.iterations

      for {measurements, metadata} <- iterations do
        assert is_integer(measurements.iteration)
        assert measurements.duration >= 0
        assert is_boolean(metadata.success)
        assert is_integer(metadata.current_length)
      end

      assert Enum.any?(iterations, fn {_, md} -> md.success end)
      assert {_, last} = List.last(iterations)
      assert last.current_length == length(PropertyDamage.Sequence.to_list(result.sequence))
    end

    test "emits one stop event that agrees with the result", %{oracle: oracle} do
      result = shrink(oracle)
      assert [{_, measurements, metadata}] = for({[_, _, :stop], _, _} = e <- events(), do: e)

      assert measurements.iterations == result.iterations
      assert measurements.duration >= 0
      assert measurements.candidate_ms >= 0
      assert measurements.setup_ms == 0
      assert measurements.teardown_ms == 0
      assert metadata == %{original_length: 5, shrunk_length: 2, stop: result.stop}
    end

    test "sums the adapter time an oracle reports into the stop event", %{oracle: oracle} do
      timed = fn plan, epoch ->
        %{oracle.(plan, epoch) | adapter_ms: %{setup: 2.5, teardown: 1.0}}
      end

      result = shrink(timed)
      assert [{_, measurements, _}] = for({[_, _, :stop], _, _} = e <- events(), do: e)

      assert measurements.setup_ms == 2.5 * result.iterations
      assert measurements.teardown_ms == 1.0 * result.iterations
    end
  end

  describe "without a handler" do
    test "the shrinker tries the same candidates with or without one" do
      calls = fn ->
        {oracle, log} = FakeOracle.start(&rule/2, O.signature())
        result = shrink(oracle)
        calls = log |> FakeOracle.calls() |> Enum.map(&{&1.plan.commands, &1.epoch})
        FakeOracle.stop(log)
        {result.iterations, calls}
      end

      plain = calls.()
      attach()
      assert calls.() == plain
    end
  end

  describe "through PropertyDamage.run" do
    test "the stop event holds the time the adapters spent in setup/1 and teardown/1" do
      attach()
      model = R.pay_model(Module.concat(__MODULE__, LedgerModel), R.Ledger)

      targets = [
        {SlowAdapter, name: "a", config: %{name: "a"}},
        {SlowAdapter, name: "b", config: %{name: "b", at: %{1 => {:sync, 1}}}}
      ]

      assert {:error, _report} = R.run(model, targets, shrink: true)
      assert [{_, measurements, _}] = for({[_, _, :stop], _, _} = e <- events(), do: e)

      # Each candidate sets up and tears down two targets, 20 ms and 10 ms each.
      assert measurements.iterations > 0
      assert measurements.setup_ms >= 20
      assert measurements.teardown_ms >= 10
      assert measurements.candidate_ms >= measurements.setup_ms
    end
  end
end
