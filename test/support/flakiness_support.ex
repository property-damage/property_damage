defmodule PropertyDamage.Test.Flake.Events do
  @moduledoc false
  # Events for the flakiness-scan fixture.

  defmodule Ok do
    @moduledoc false
    defstruct [:amount]
  end

  defmodule Bad do
    @moduledoc false
    defstruct [:amount]
  end
end

defmodule PropertyDamage.Test.Flake.Op do
  @moduledoc """
  Single command for the flakiness-scan fixture. Carries an `amount` drawn
  deterministically from the run seed; the adapter bands that amount to decide
  whether a given seed is stable, always-broken, or intermittently flaky.
  """
  use PropertyDamage.Command, observables: [PropertyDamage.Test.Flake.Events.Ok]

  import PropertyDamage.Generator, only: [merge_overrides: 2]

  defstruct [:amount]

  @impl true
  def generator(overrides \\ %{}) do
    %{amount: StreamData.integer(1..100)}
    |> merge_overrides(overrides)
    |> StreamData.fixed_map()
  end
end

defmodule PropertyDamage.Test.Flake.State do
  @moduledoc false
  # command_sequence_projection: Op has no precondition so this stays trivial.
  use PropertyDamage.Model.Projection

  @impl true
  def init, do: %{}

  @impl true
  def apply(state, _), do: state
end

defmodule PropertyDamage.Test.Flake.Health do
  @moduledoc false
  # Assertion projection: any Bad event flips the run to failing.
  use PropertyDamage.Model.Projection

  alias PropertyDamage.Test.Flake.Events.Bad

  @impl true
  def init, do: %{ok: true}

  @impl true
  def apply(state, %Bad{}), do: %{state | ok: false}
  def apply(state, _), do: state

  @trigger every: 1
  def assert_healthy(%{ok: false}, _cmd_or_event) do
    PropertyDamage.fail!("flaked: a Bad event was observed")
  end

  def assert_healthy(_state, _cmd_or_event), do: :ok
end

defmodule PropertyDamage.Test.Flake.Model do
  @moduledoc """
  Flakiness-scan fixture model. Runs exactly one `Op` per sequence so each
  captured run exercises a single, seed-determined command against the
  banding adapter.
  """
  @behaviour PropertyDamage.Model
  @behaviour PropertyDamage.Model.Simulator

  alias PropertyDamage.Test.Flake.Events.Ok
  alias PropertyDamage.Test.Flake.{Health, State}
  alias PropertyDamage.Test.Flake.Op

  @impl true
  def commands, do: [Op]

  @impl true
  def command_sequence_projection, do: State

  @impl true
  def assertion_projections, do: [Health]

  @impl true
  def simulator, do: __MODULE__

  @impl PropertyDamage.Model.Simulator
  def simulate(%Op{amount: amount}, _state) do
    [%Ok{amount: amount}]
  end

  @impl true
  def terminate?(_state, %Op{}, _events), do: true
end

defmodule PropertyDamage.Test.Flake.Adapter do
  @moduledoc """
  Banding adapter for the flakiness-scan fixture.

  The seed-derived `amount` selects one of three behaviors, so a seed's verdict
  is a deterministic function of the seed:

    * `amount <= 33` — **broken**: always emits a Bad event (every run fails).
    * `34..66` — **flaky**: emits Ok/Bad alternately, driven by a shared
      `:counters` reference passed in `adapter_config[:counter]`. Alternation
      over N >= 2 captures guarantees a passing/failing mix, so the seed is
      reliably reported flaky.
    * `amount >= 67` — **stable**: always emits an Ok event (every run passes).

  A counter (rather than the FI fixture's pure-function-of-seed switch) is used
  deliberately: `RunTrace.capture/1` never shrinks, so there are no shrink
  re-runs whose determinism a counter could break; the counter is only what
  makes the flaky band produce a *guaranteed* outcome mix across the N captures
  of one plan (the same plan differs across runs only in its random
  `run_nonce`, which is not observable by the adapter).
  """
  use PropertyDamage.Adapter

  alias PropertyDamage.Test.Flake.Events.{Bad, Ok}
  alias PropertyDamage.Test.Flake.Op

  @impl true
  def setup(config), do: {:ok, config}

  @impl true
  def teardown(_context), do: :ok

  @impl true
  def execute(%Op{amount: amount}, config, _runtime) do
    case band(amount) do
      :broken -> {:ok, [%Bad{amount: amount}]}
      :stable -> {:ok, [%Ok{amount: amount}]}
      :flaky -> flaky(config, amount)
    end
  end

  defp band(amount) when amount <= 33, do: :broken
  defp band(amount) when amount <= 66, do: :flaky
  defp band(_amount), do: :stable

  defp flaky(%{counter: ref}, amount) do
    n = :counters.get(ref, 1)
    :counters.add(ref, 1, 1)
    if rem(n, 2) == 0, do: {:ok, [%Ok{amount: amount}]}, else: {:ok, [%Bad{amount: amount}]}
  end
end
