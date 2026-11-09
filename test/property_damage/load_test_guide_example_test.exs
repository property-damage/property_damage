defmodule PropertyDamage.LoadTestGuideExampleTest do
  @moduledoc """
  The runnable example of `guides/load_testing.md` (a tally with a setup
  command, a root, a teardown command and an `@eventually` check) run through
  `PropertyDamage.LoadTest.run/1`.

  The module bodies are the guide's, placed under this module so their names do
  not collide. The guide leaves nothing to the reader, so the test defines only
  its assertions.
  """
  use ExUnit.Case, async: false

  alias PropertyDamage.LoadTest

  # --- the guide's example ---------------------------------------------------

  defmodule Tally.Open do
    use PropertyDamage.Command
    defstruct []

    @impl true
    def generator(overrides \\ %{}) do
      %{}
      |> PropertyDamage.Generator.merge_overrides(overrides)
      |> StreamData.fixed_map()
    end
  end

  defmodule Tally.Put do
    use PropertyDamage.Command
    defstruct [:value]

    @impl true
    def generator(overrides \\ %{}) do
      %{value: StreamData.integer(1..9)}
      |> PropertyDamage.Generator.merge_overrides(overrides)
      |> StreamData.fixed_map()
    end
  end

  defmodule Tally.Close do
    use PropertyDamage.Command
    defstruct []

    @impl true
    def generator(overrides \\ %{}) do
      %{}
      |> PropertyDamage.Generator.merge_overrides(overrides)
      |> StreamData.fixed_map()
    end
  end

  defmodule Tally.Opened, do: defstruct([])
  defmodule Tally.Stored, do: defstruct([:value])
  defmodule Tally.Closed, do: defstruct([])

  defmodule Tally.Adapter do
    use PropertyDamage.Adapter

    @impl true
    def setup(_config), do: Agent.start_link(fn -> nil end)

    @impl true
    def teardown(store), do: Agent.stop(store)

    @impl true
    def execute(%Tally.Open{}, store, _runtime) do
      Agent.update(store, fn _ -> 0 end)
      {:ok, [%Tally.Opened{}]}
    end

    def execute(%Tally.Put{value: value}, store, _runtime) do
      Agent.update(store, fn _ -> value end)
      {:ok, [%Tally.Stored{value: value}]}
    end

    def execute(%Tally.Close{}, store, _runtime) do
      Agent.update(store, fn _ -> nil end)
      {:ok, [%Tally.Closed{}]}
    end
  end

  defmodule Tally.Projection do
    use PropertyDamage.Model.Projection

    @impl true
    def init, do: %{stored: nil}

    @impl true
    def apply(state, %Tally.Stored{value: value}), do: %{state | stored: value}
    def apply(state, _event), do: state

    # Runs after every `Stored` event, and the load run waits for it to hold.
    @eventually after: Tally.Stored, timeout: {1, :seconds}, interval: {5, :milliseconds}
    def value_is_stored(_state, %Tally.Stored{value: value}) do
      fn state -> state.stored == value end
    end
  end

  defmodule Tally.Model do
    use PropertyDamage.Model

    @impl true
    def commands, do: [Tally.Put]

    @impl true
    def setup_each, do: [Tally.Open]

    @impl true
    def teardown_each, do: [Tally.Close]

    @impl true
    def command_sequence_projection, do: Tally.Projection

    @impl true
    def check_projections, do: [Tally.Projection]
  end

  defp run_example(opts) do
    LoadTest.run(
      Keyword.merge(
        [
          model: Tally.Model,
          targets: [Tally.Adapter],
          arrival_rate: 20,
          duration: {1, :seconds},
          check_mode: :record
        ],
        opts
      )
    )
  end

  test "the guide's example runs the setup, teardown, eventual and stutter phases" do
    assert {:ok, report} =
             run_example(stutter: [probability: 1.0, max_repeats: 1, delay_ms: 0])

    counts = report.metrics.phase_counts
    assert counts.setup_commands > 0
    assert counts.teardown_commands > 0
    assert counts.eventual_checks > 0
    assert counts.stutter_retries > 0
    assert report.metrics.check_failures == 0
    assert report.metrics.total_errors == 0

    # Setup and teardown commands are phases, not requests.
    assert Map.keys(report.metrics.by_command) == [Tally.Put]
    assert counts.setup_commands == counts.teardown_commands
    assert LoadTest.summary(report) =~ "Phases: #{counts.setup_commands} setup commands"
  end

  test "with check_mode disabled the example opens no eventual check" do
    assert {:ok, report} = run_example(check_mode: :disabled)

    counts = report.metrics.phase_counts
    assert counts.setup_commands > 0
    assert counts.teardown_commands > 0
    assert counts.eventual_checks == 0
    assert counts.stutter_retries == 0
  end
end
