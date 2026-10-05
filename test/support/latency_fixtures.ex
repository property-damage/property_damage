defmodule PropertyDamage.Test.LatencyFixtures do
  @moduledoc false
  # Fixtures for the multi-target tests of what a run times and of producers
  # that error under lockstep.
  #
  # `SlowFoldModel` folds every event through a projection that sleeps, so a
  # step takes far longer than its adapter call. `RefusingMintAdapter` mints
  # `external()` ids for `Create` unless its config says `refuse_create: true`.

  alias PropertyDamage.Test.Lockstep.{Create, Created, Step, Stepped, Use, Used}

  defmodule SlowFold do
    @moduledoc false
    # Sleeps `sleep_ms` (40) in every apply/2.
    @behaviour PropertyDamage.Model.Projection

    @sleep_ms 40

    def sleep_ms, do: @sleep_ms

    @impl true
    def init, do: %{seen: 0}

    @impl true
    def apply(state, _event) do
      Process.sleep(@sleep_ms)
      %{state | seen: state.seen + 1}
    end
  end

  defmodule SlowFoldModel do
    @moduledoc false
    @behaviour PropertyDamage.Model

    @impl true
    def commands, do: [Step]

    @impl true
    def command_sequence_projection, do: SlowFold
  end

  defmodule TimedStepAdapter do
    @moduledoc false
    # Answers each Step at once, or after `sleep_ms` when the config sets it.
    use PropertyDamage.Adapter

    @impl true
    def setup(config), do: {:ok, config}

    @impl true
    def teardown(_ctx), do: :ok

    @impl true
    def execute(%Step{value: value}, ctx, _runtime) do
      if sleep = ctx[:sleep_ms], do: Process.sleep(sleep)
      {:ok, [%Stepped{value: value}]}
    end
  end

  defmodule RefusingMintAdapter do
    @moduledoc false
    # Mints `<prefix>_id_<n>` for each Create, or refuses it when
    # `refuse_create: true`; echoes each Use's resolved target. Every command
    # it receives is sent to `test_pid` as {:received, prefix, command}.
    use PropertyDamage.Adapter

    alias PropertyDamage.Test.Lockstep

    @impl true
    def setup(config), do: {:ok, Map.put(config, :minted, :atomics.new(1, []))}

    @impl true
    def teardown(_ctx), do: :ok

    @impl true
    def execute(%Create{label: label} = command, ctx, _runtime) do
      Lockstep.notify(ctx, {:received, ctx.prefix, command})

      if ctx[:refuse_create] do
        {:error, :refused}
      else
        n = :atomics.add_get(ctx.minted, 1, 1)
        {:ok, [%Created{label: label, id: "id_#{n}"}]}
      end
    end

    def execute(%Use{target: target} = command, ctx, _runtime) do
      Lockstep.notify(ctx, {:received, ctx.prefix, command})
      {:ok, [%Used{target: target}]}
    end
  end
end
