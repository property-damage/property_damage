defmodule PropertyDamage.ExternalE2ETest do
  @moduledoc """
  R3 cluster C: end-to-end external() producer -> consumer (DR-021).

  A producer command yields a server-generated id (declared `external()` on its
  event); the framework captures the real value by the producer's structured
  position and a downstream consumer command receives the concrete value, not a
  `%Placeholder{}` / `%External{}` sentinel. This is the headline path the suite
  never exercised before R3.
  """
  use ExUnit.Case, async: true

  alias PropertyDamage.{Executor, Generator, Placeholder, PlaceholderRegistry, Sequence}

  defmodule Created do
    import PropertyDamage, only: [external: 0]
    defstruct [:label, id: external()]
  end

  defmodule Create do
    @behaviour PropertyDamage.Command
    defstruct [:label]
    @impl true
    def generator(overrides) do
      StreamData.fixed_map(
        Generator.merge_overrides(%{label: StreamData.constant("x")}, overrides)
      )
    end
  end

  defmodule Use do
    @behaviour PropertyDamage.Command
    defstruct [:target]
    @impl true
    def generator(overrides) do
      StreamData.fixed_map(
        Generator.merge_overrides(%{target: StreamData.constant(nil)}, overrides)
      )
    end
  end

  defmodule Projection do
    @behaviour PropertyDamage.Model.Projection
    @impl true
    def init, do: %{created: []}
    @impl true
    def apply(state, %Create{}), do: state
    def apply(state, %Created{id: id}), do: %{state | created: [id | state.created]}
    def apply(state, %Use{}), do: state
    def apply(state, _other), do: state
  end

  # Adapter: Create returns a concrete server id; Use reports the target it was
  # handed so the test can assert the value is concrete.
  defmodule Adapter do
    use PropertyDamage.Adapter

    @impl true
    def setup(config), do: {:ok, config}

    @impl true
    def execute(%Create{}, _ctx) do
      n = System.unique_integer([:positive])
      {:ok, [%Created{label: "x", id: "real_#{n}"}]}
    end

    def execute(%Use{target: target}, %{test_pid: pid}) do
      send(pid, {:used, target})
      {:ok, []}
    end

    @impl true
    def teardown(_ctx), do: :ok
  end

  defmodule PlainModel do
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

  defmodule RoutingModel do
    @behaviour PropertyDamage.Model
    @behaviour PropertyDamage.Model.Simulator
    @impl true
    def commands do
      [
        Create,
        {Use,
         when: fn state -> state.created != [] end,
         with: fn state -> %{target: Generator.external_from(state, path: [:id])} end}
      ]
    end

    @impl true
    def command_sequence_projection, do: Projection
    @impl true
    def simulator, do: __MODULE__
    @impl PropertyDamage.Model.Simulator
    def simulate(%Create{label: l}, _state), do: [%Created{label: l}]
    def simulate(_command, _state), do: []
  end

  describe "deterministic capture (hand-built sequence)" do
    test "consumer receives the concrete server value captured from the producer" do
      ph = Placeholder.new_at(Created, [:id], {:prefix, 0}, 0)
      reg = PlaceholderRegistry.new() |> PlaceholderRegistry.register(ph)

      seq =
        [%Create{label: "x"}, %Use{target: ph}]
        |> Sequence.linear()
        |> Sequence.with_registry(reg)

      {:ok, result} =
        Executor.run(seq, PlainModel, Adapter, adapter_config: %{test_pid: self()})

      assert result.failed_at_index == nil
      assert_received {:used, target}
      assert is_binary(target)
      assert String.starts_with?(target, "real_")
    end
  end

  describe "generation-driven end to end" do
    test "no Use sees an unresolved external, and at least one consumes a real id" do
      # Find a seed whose generated sequence actually routes a placeholder into a
      # Use command, so the assertion is non-vacuous rather than trivially true.
      seq =
        Enum.find_value(1..200, fn seed ->
          s =
            RoutingModel
            |> Generator.generate_sequence(max_commands: 12)
            |> Generator.generate_value(seed)

          if Enum.any?(Sequence.to_list(s), &match?(%Use{target: %Placeholder{}}, &1)) do
            s
          end
        end)

      assert seq, "no seed produced a Use carrying a placeholder target"

      {:ok, result} =
        Executor.run(seq, RoutingModel, Adapter, adapter_config: %{test_pid: self()})

      assert result.failed_at_index == nil

      targets = drain_used([])
      assert Enum.any?(targets, &is_binary/1), "expected at least one Use to execute"

      Enum.each(targets, fn t ->
        refute match?(%Placeholder{}, t)
        refute match?(%PropertyDamage.External{}, t)
      end)

      assert Enum.any?(targets, fn t -> is_binary(t) and String.starts_with?(t, "real_") end)
    end
  end

  defp drain_used(acc) do
    receive do
      {:used, target} -> drain_used([target | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
