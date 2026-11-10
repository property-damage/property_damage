defmodule PropertyDamage.ReportRunNumberTest do
  # A report's run number counts from 1, as the one-line summary prints it and
  # as `only: [run: n]` takes it.
  use ExUnit.Case, async: true

  alias PropertyDamage.FailureReport

  defmodule Poke do
    @moduledoc false
    use PropertyDamage.Command
    defstruct [:n]

    @impl true
    def generator(overrides \\ %{}) do
      %{n: StreamData.integer(1..3)}
      |> PropertyDamage.Generator.merge_overrides(overrides)
      |> StreamData.fixed_map()
    end
  end

  defmodule Poked do
    @moduledoc false
    defstruct [:n]
  end

  defmodule Tripwire do
    @moduledoc false
    use PropertyDamage.Model.Projection

    @impl true
    def init, do: %{poked: false}

    @impl true
    def apply(state, %Poked{}), do: %{state | poked: true}
    def apply(state, _event), do: state

    @check every: 1
    def never_poked(state, _), do: not state.poked or PropertyDamage.fail!("poked")
  end

  defmodule Model do
    @moduledoc false
    use PropertyDamage.Model

    @impl true
    def commands, do: [Poke]

    @impl true
    def command_sequence_projection, do: Tripwire

    @impl true
    def check_projections, do: [Tripwire]
  end

  defmodule Adapter do
    @moduledoc false
    use PropertyDamage.Adapter

    @impl true
    def setup(config), do: {:ok, config}

    @impl true
    def teardown(_context), do: :ok

    @impl true
    def execute(%Poke{n: n}, _context, _runtime), do: {:ok, [%Poked{n: n}]}
  end

  defp run(opts) do
    PropertyDamage.run([model: Model, targets: [Adapter], replay_dir: false] ++ opts)
  end

  test "the first run's failure is run 1 in the accessor, the summary and only: [run: n]" do
    assert {:error, report} = run(seed: 5, max_runs: 3)

    assert FailureReport.run_number(report) == 1
    assert inspect(report) =~ "run=1 "

    assert {:error, again} =
             run(seed: FailureReport.seed(report), only: [run: FailureReport.run_number(report)])

    assert FailureReport.check_name(again) == FailureReport.check_name(report)
  end
end
