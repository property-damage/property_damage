defmodule PropertyDamage.PlaceholderTransportTest do
  @moduledoc """
  R3 cluster B: the executor seeds its placeholder registry from the generated
  sequence (DR-021), so placeholders embedded in commands resolve by id at
  execution time.

  Before this cluster the executor always started with an empty
  `PlaceholderRegistry.new()`, so an embedded placeholder could never be found
  (it raised "Unknown placeholder" and the command errored).
  """
  use ExUnit.Case, async: true

  alias PropertyDamage.Sequence.Position

  alias PropertyDamage.{Executor, Placeholder, PlaceholderRegistry, Sequence}

  defmodule SomeEvent do
    defstruct [:id]
  end

  defmodule UseExternal do
    defstruct [:order_id]
  end

  defmodule NoopProjection do
    @behaviour PropertyDamage.Model.Projection
    @impl true
    def init, do: %{}
    @impl true
    def apply(state, _item), do: state
  end

  defmodule Model do
    @behaviour PropertyDamage.Model
    @impl true
    def commands, do: []
    @impl true
    def command_sequence_projection, do: NoopProjection
  end

  defmodule RecordingAdapter do
    use PropertyDamage.Adapter

    @impl true
    def setup(config), do: {:ok, config}
    @impl true
    def execute(command, %{test_pid: pid}, _runtime) do
      send(pid, {:executed, command})
      {:ok, []}
    end

    @impl true
    def teardown(_context), do: :ok
  end

  defp resolved_registry(placeholder, value) do
    PlaceholderRegistry.new()
    |> PlaceholderRegistry.register(placeholder)
    |> PlaceholderRegistry.resolve(placeholder.id, value)
  end

  test "embedded placeholder resolves to its concrete value when the sequence carries the registry" do
    ph = Placeholder.new_at(SomeEvent, [:id], Position.prefix(0), 0)
    reg = resolved_registry(ph, "ord_123")

    seq =
      [%UseExternal{order_id: ph}]
      |> Sequence.linear()
      |> Sequence.with_registry(reg)

    {:ok, _result} =
      Executor.run(seq, Model, RecordingAdapter, adapter_config: %{test_pid: self()})

    assert_received {:executed, %UseExternal{order_id: "ord_123"}}
  end

  test "without the carried registry the same command fails to resolve the placeholder" do
    # Mirrors the pre-fix behavior: no registry on the sequence means the
    # executor starts empty and cannot resolve the embedded placeholder.
    ph = Placeholder.new_at(SomeEvent, [:id], Position.prefix(0), 0)

    seq = Sequence.linear([%UseExternal{order_id: ph}])

    {:ok, result} =
      Executor.run(seq, Model, RecordingAdapter, adapter_config: %{test_pid: self()})

    refute_received {:executed, _}
    assert match?(%{failed_at_index: 0}, result)
  end
end
