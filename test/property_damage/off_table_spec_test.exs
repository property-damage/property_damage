defmodule PropertyDamage.OffTableSpecTest do
  @moduledoc """
  A command module the model's spec table does not hold (a hand-built
  sequence, a leaf an expansion generates) still gets its own `command_spec/1`
  at execution time, not a missing spec.
  """
  use ExUnit.Case, async: false

  alias PropertyDamage.Sequence

  alias PropertyDamage.Test.StepRun

  defmodule Unlisted do
    @moduledoc false
    use PropertyDamage.Command, idempotent: false

    defstruct [:id]

    @impl true
    def generator(_overrides \\ %{}), do: StreamData.constant(%{})
  end

  defmodule Listed do
    @moduledoc false
    use PropertyDamage.Command

    defstruct [:id]

    @impl true
    def generator(_overrides \\ %{}), do: StreamData.constant(%{})
  end

  defmodule Passthrough do
    @moduledoc false
    @behaviour PropertyDamage.Model.Projection
    @impl true
    def init, do: %{}
    @impl true
    def apply(state, _event), do: state
  end

  defmodule Model do
    @moduledoc false
    use PropertyDamage.Model
    @impl true
    def commands, do: [Listed]
    @impl true
    def command_sequence_projection, do: Passthrough
  end

  defmodule CountingAdapter do
    @moduledoc false
    use PropertyDamage.Adapter

    defmodule Done, do: defstruct([:id])

    @impl true
    def setup(config), do: {:ok, config}
    @impl true
    def teardown(_context), do: :ok

    @impl true
    def execute(command, _ctx, _runtime) do
      Agent.update(__MODULE__.Calls, &[command.__struct__ | &1])
      {:ok, [%Done{id: command.id}]}
    end
  end

  @always_stutter %PropertyDamage.Stutter.Config{
    probability: 1.0,
    max_repeats: 1,
    delay_ms: 0,
    commands: :all,
    enabled: true
  }

  defp run(command) do
    start_supervised!(%{
      id: CountingAdapter.Calls,
      start: {Agent, :start_link, [fn -> [] end, [name: CountingAdapter.Calls]]}
    })

    {:ok, _result} =
      StepRun.run(Sequence.linear([command]), Model, CountingAdapter,
        stutter_config: @always_stutter,
        rng_seed: 7
      )

    Agent.get(CountingAdapter.Calls, & &1)
  end

  test "a command the model does not list keeps its own idempotent: false under stutter" do
    assert run(%Unlisted{id: 1}) == [Unlisted]
  end

  test "a listed idempotent command is re-sent under the same stutter" do
    assert run(%Listed{id: 1}) == [Listed, Listed]
  end
end
