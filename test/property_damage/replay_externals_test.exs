defmodule PropertyDamage.ReplayExternalsTest do
  @moduledoc """
  Regression: replaying a failure whose commands consume `external()` values
  must resolve them, not crash with "Unknown placeholder" (DR-021).

  The bug: `Replay.do_start` never threaded the failing sequence's placeholder
  registry into `Stepping.init_state`, so the stepping engine started with an
  empty registry. The producer's real event then had no `producer_link` to
  capture against, the consumer's `%Placeholder{}` never resolved, and
  resolution raised. The fix seeds the registry from the sequence.
  """
  use ExUnit.Case, async: false

  alias PropertyDamage.Sequence.Position

  alias PropertyDamage.{FailureReport, Placeholder, PlaceholderRegistry, Replay, Sequence}

  defmodule Created do
    import PropertyDamage, only: [external: 0]
    defstruct [:label, id: external()]
  end

  defmodule Create do
    @behaviour PropertyDamage.Command
    defstruct [:label]
    @impl true
    def generator(_overrides), do: StreamData.constant(%{label: "x"})
  end

  defmodule Use do
    @behaviour PropertyDamage.Command
    defstruct [:target]
    @impl true
    def generator(_overrides), do: StreamData.constant(%{target: nil})
  end

  defmodule Projection do
    @behaviour PropertyDamage.Model.Projection
    @impl true
    def init, do: %{created: []}
    @impl true
    def apply(state, %Created{id: id}), do: %{state | created: [id | state.created]}
    def apply(state, _other), do: state
  end

  defmodule Model do
    @behaviour PropertyDamage.Model
    @behaviour PropertyDamage.Model.Simulator
    @impl true
    def commands, do: [Create, Use]
    @impl true
    def command_sequence_projection, do: Projection
    @impl true
    def simulator, do: __MODULE__
    @impl PropertyDamage.Model.Simulator
    def simulate(%Create{label: l}, _state), do: [%Created{label: l}]
    def simulate(_command, _state), do: []
  end

  defmodule Adapter do
    use PropertyDamage.Adapter
    @impl true
    def setup(config), do: {:ok, config}
    @impl true
    def teardown(_ctx), do: :ok
    @impl true
    def execute(%Create{label: label}, _ctx, _runtime) do
      n = System.unique_integer([:positive])
      {:ok, [%Created{label: label, id: "real_#{n}"}]}
    end

    def execute(%Use{target: target}, %{test_pid: pid}, _runtime) do
      send(pid, {:used, target})
      {:ok, []}
    end
  end

  defp external_failure do
    ph = Placeholder.new_at(Created, [:id], Position.prefix(0), 0)
    reg = PlaceholderRegistry.new() |> PlaceholderRegistry.register(ph)

    seq =
      [%Create{label: "x"}, %Use{target: ph}]
      |> Sequence.linear()
      |> Sequence.with_registry(reg)

    FailureReport.new(
      seed: 1,
      run_number: 0,
      original_sequence: seq,
      shrunk_sequence: seq,
      failed_at_index: 1,
      failure_reason: {:check_failed, :Dummy, "for replay"},
      model: Model,
      adapter: Adapter
    )
  end

  test "replaying an external()-consuming failure resolves the placeholder" do
    failure = external_failure()

    assert {:ok, steps} =
             Replay.run(failure, adapter_config: %{test_pid: self()})

    assert length(steps) == 2

    # The consumer received the concrete server value the producer emitted, not
    # a %Placeholder{} sentinel (which is what the missing-registry bug left it).
    assert_received {:used, target}
    refute match?(%Placeholder{}, target)
    assert is_binary(target) and String.starts_with?(target, "real_")
  end
end
