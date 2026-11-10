defmodule PropertyDamage.LoadTest.WorkerPhaseCountTest do
  # What `phase_counts` counts today: `stutter_retries` counts the retries
  # whose events the event log kept, so a retry that answers no events is not
  # counted; `eventual_checks` counts the `@eventually` windows a session
  # opened, so a window that never reaches a verdict still counts.
  use ExUnit.Case, async: true

  alias PropertyDamage.Generator
  alias PropertyDamage.LoadTest.{Metrics, Worker}
  alias PropertyDamage.Stutter

  defmodule Acted do
    defstruct []
  end

  defmodule Act do
    @behaviour PropertyDamage.Command
    defstruct []

    @impl true
    def generator(overrides \\ %{}),
      do: StreamData.fixed_map(Generator.merge_overrides(%{}, overrides))
  end

  defmodule Rules do
    use PropertyDamage.Model.Projection

    @impl true
    def init, do: %{acts: 0}

    @impl true
    def apply(state, %Acted{}), do: %{state | acts: state.acts + 1}
    def apply(state, _other), do: state

    # Fails the second `Act`, so a halting session ends at its second root.
    @check every: Act
    def at_most_one_act(state, _command),
      do: state.acts < 2 or PropertyDamage.fail!("one act allowed")

    @eventually after: Acted, timeout: {1, :seconds}, interval: {5, :milliseconds}
    def acts_settle(_state, %Acted{}), do: fn state -> state.acts >= 1 end
  end

  defmodule Model do
    @behaviour PropertyDamage.Model.Simulator
    use PropertyDamage.Model

    @impl true
    def commands, do: [Act]

    @impl true
    def command_sequence_projection, do: Rules

    @impl true
    def check_projections, do: [Rules]

    @impl true
    def simulator, do: __MODULE__

    @impl PropertyDamage.Model.Simulator
    def simulate(%Act{}, _state), do: [%Acted{}]
  end

  # `:events` is what the adapter answers to an `Act`.
  defmodule Adapter do
    use PropertyDamage.Adapter, default_timeout: 1_000

    @impl true
    def setup(config), do: {:ok, config}

    @impl true
    def teardown(_ctx), do: :ok

    @impl true
    def execute(%Act{}, %{events: events}, _runtime), do: {:ok, events}
  end

  defp session(events, opts) do
    {:ok, metrics} = Metrics.start_link()

    {:ok, worker} =
      Worker.start_link(
        [
          worker_id: 1,
          seed: 7,
          model: Model,
          target: %PropertyDamage.Target{
            adapter: Adapter,
            config: %{events: events},
            name: "counts",
            index: 0
          },
          metrics: metrics,
          think_time_range: {0, 0}
        ] ++ opts
      )

    {:ok, stats} = Worker.execute_sequence(worker)
    Worker.stop(worker)
    counts = Metrics.snapshot(metrics).phase_counts
    Metrics.stop(metrics)
    {stats, counts}
  end

  defp stutter_all,
    do: struct!(Stutter.Config, probability: 1.0, max_repeats: 1, delay_ms: 0, commands: :all)

  test "a stutter retry that answers events is counted, one that answers none is not" do
    {answered, answered_counts} =
      session([%Acted{}], check_mode: :disabled, stutter_config: stutter_all())

    {silent, silent_counts} =
      session([], check_mode: :disabled, stutter_config: stutter_all())

    assert answered_counts.stutter_retries == answered.commands_run
    assert silent.commands_run > 0
    assert silent_counts.stutter_retries == 0
  end

  test "an eventual window counts when it opens, even if its session halts before a verdict" do
    {stats, counts} = session([%Acted{}], check_mode: :halt)

    # The second root fails its check and ends the session; the window the
    # first root opened is counted although the session reached no verdict for it.
    assert stats.commands_run == 2
    assert counts.eventual_checks == 1
  end
end
