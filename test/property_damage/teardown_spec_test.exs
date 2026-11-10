defmodule PropertyDamage.TeardownSpecTest do
  @moduledoc """
  A teardown command runs with the spec its `teardown_each/0` listing gives
  it, so a listing that marks it `execution: :probe` settles it like any other
  command: the adapter's `{:retry, _}` answers are retried until one succeeds.
  """
  use ExUnit.Case, async: true

  alias PropertyDamage.Sequence
  alias PropertyDamage.Test.StepRun

  defmodule Cleanup do
    @moduledoc false
    use PropertyDamage.Command

    defstruct [:id]

    @impl true
    def generator(_overrides \\ %{}), do: StreamData.constant(%{})
  end

  defmodule Cleaned do
    @moduledoc false
    defstruct [:id]
  end

  defmodule PassthroughProjection do
    @moduledoc false
    use PropertyDamage.Model.Projection

    @impl true
    def init, do: %{}

    @impl true
    def apply(state, _event), do: state
  end

  defmodule Model do
    @moduledoc false
    use PropertyDamage.Model

    @impl true
    def commands, do: []

    @impl true
    def command_sequence_projection, do: PassthroughProjection

    @impl true
    def teardown_each do
      [
        {Cleanup,
         execution: :probe, settle: %{timeout_ms: 2_000, interval_ms: 1, backoff: :linear}}
      ]
    end
  end

  defmodule Adapter do
    @moduledoc false
    use PropertyDamage.Adapter

    @impl true
    def setup(config), do: {:ok, config}

    @impl true
    def teardown(_context), do: :ok

    # Answers `{:retry, :not_ready}` until the third attempt.
    @impl true
    def execute(%Cleanup{id: id}, %{attempts: attempts}, _runtime) do
      :counters.add(attempts, 1, 1)

      if :counters.get(attempts, 1) < 3,
        do: {:retry, :not_ready},
        else: {:ok, [%Cleaned{id: id}]}
    end
  end

  test "a teardown command listed as a probe is retried until it succeeds" do
    attempts = :counters.new(1, [])

    {:ok, result} =
      StepRun.run(Sequence.linear([]), Model, Adapter,
        config: %{attempts: attempts},
        teardown_commands: [%Cleanup{id: "x"}]
      )

    assert :counters.get(attempts, 1) == 3
    assert Enum.any?(result.event_log, &match?(%Cleaned{id: "x"}, &1.event))
  end
end
