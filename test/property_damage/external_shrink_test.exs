defmodule PropertyDamage.ExternalShrinkTest do
  @moduledoc """
  R3 cluster D: shrinking a sequence that uses external() preserves resolution
  (DR-021).

  Shrinking removes commands, shifting positions. The placeholder registry's
  producer_link is keyed by position, so it must be remapped onto each
  candidate's positions; otherwise a surviving consumer's placeholder never
  resolves, the candidate fails with a *different* error, and shrinking stalls
  (cannot reach the minimal repro).
  """
  use ExUnit.Case, async: true

  alias PropertyDamage.{Executor, Placeholder, PlaceholderRegistry, Sequence, Shrinker}

  defmodule Created do
    import PropertyDamage, only: [external: 0]
    defstruct id: external()
  end

  defmodule Create do
    @behaviour PropertyDamage.Command
    defstruct []
    @impl true
    def generator(_overrides), do: StreamData.constant(%{})
  end

  defmodule Noise do
    @behaviour PropertyDamage.Command
    defstruct []
    @impl true
    def generator(_overrides), do: StreamData.constant(%{})
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
    def init, do: %{}
    @impl true
    def apply(state, _item), do: state
  end

  defmodule Model do
    @behaviour PropertyDamage.Model
    @impl true
    def commands, do: [Create, Noise, Use]
    @impl true
    def command_sequence_projection, do: Projection
  end

  # Create yields a concrete id; Use fails only when it actually received that
  # concrete id (proving the external resolved). If the placeholder is left
  # unresolved the executor errors earlier with a different signature.
  defmodule Adapter do
    use PropertyDamage.Adapter

    @impl true
    def setup(config), do: {:ok, config}

    @impl true
    def execute(%Create{}, _ctx) do
      {:ok, [%Created{id: "real_#{System.unique_integer([:positive])}"}]}
    end

    def execute(%Noise{}, _ctx), do: {:ok, []}

    def execute(%Use{target: target}, _ctx) do
      if is_binary(target) and String.starts_with?(target, "real_") do
        {:error, :consumer_saw_real_id}
      else
        {:ok, []}
      end
    end

    @impl true
    def teardown(_ctx), do: :ok
  end

  test "a padded producer->consumer failure shrinks to the minimal pair and still resolves" do
    ph = Placeholder.new_at(Created, [:id], {:prefix, 0}, 0)
    reg = PlaceholderRegistry.new() |> PlaceholderRegistry.register(ph)

    full =
      [%Create{}, %Noise{}, %Noise{}, %Noise{}, %Use{target: ph}]
      |> Sequence.linear()
      |> Sequence.with_registry(reg)

    # Establish the original failure (adapter error at the Use command).
    {:ok, result} = Executor.run(full, Model, Adapter, adapter_config: %{})
    assert result.failed_at_index == 4
    assert match?({:adapter_error, :consumer_saw_real_id}, result.failure_reason)

    shrunk =
      Shrinker.shrink(full,
        failed_at_index: result.failed_at_index,
        failure_reason: result.failure_reason,
        model: Model,
        adapter: Adapter,
        adapter_config: %{}
      )

    commands = Sequence.to_list(shrunk.sequence)

    # Minimal repro is exactly the producer + consumer; the noise is gone.
    assert length(commands) == 2
    assert [%Create{}, %Use{}] = commands

    # And the shrunk sequence still reproduces the original failure, which is
    # only possible if its consumer's external resolved against the remapped
    # producer position.
    {:ok, replay} = Executor.run(shrunk.sequence, Model, Adapter, adapter_config: %{})
    assert match?({:adapter_error, :consumer_saw_real_id}, replay.failure_reason)
  end

  test "hierarchical shrinking (long sequence) preserves the producer->consumer dependency" do
    # Above the granularity threshold (8) the hierarchical strategy runs, which
    # relies on the dependency graph mapping each placeholder to its producer by
    # structured position. The producer (index 0) must be pulled back whenever
    # the consumer survives, and the shrunk sequence must still resolve.
    ph = Placeholder.new_at(Created, [:id], {:prefix, 0}, 0)
    reg = PlaceholderRegistry.new() |> PlaceholderRegistry.register(ph)

    noise = List.duplicate(%Noise{}, 12)

    full =
      ([%Create{}] ++ noise ++ [%Use{target: ph}])
      |> Sequence.linear()
      |> Sequence.with_registry(reg)

    {:ok, result} = Executor.run(full, Model, Adapter, adapter_config: %{})
    assert match?({:adapter_error, :consumer_saw_real_id}, result.failure_reason)

    shrunk =
      Shrinker.shrink(full,
        failed_at_index: result.failed_at_index,
        failure_reason: result.failure_reason,
        model: Model,
        adapter: Adapter,
        adapter_config: %{}
      )

    commands = Sequence.to_list(shrunk.sequence)
    assert [%Create{}, %Use{}] = commands

    {:ok, replay} = Executor.run(shrunk.sequence, Model, Adapter, adapter_config: %{})
    assert match?({:adapter_error, :consumer_saw_real_id}, replay.failure_reason)
  end
end
