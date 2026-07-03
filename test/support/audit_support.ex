defmodule PropertyDamage.Test.Audit.PassthroughProjection do
  @moduledoc false
  use PropertyDamage.Model.Projection

  @impl true
  def init, do: %{count: 0}

  @impl true
  def apply(%{count: n} = state, _cmd_or_event), do: %{state | count: n + 1}
end

defmodule PropertyDamage.Test.Audit.Commands.ImpureCreate do
  @moduledoc """
  IMPURE command: its generator reads `System.unique_integer/1`, process-global
  state that varies within a process. Two same-seed generations therefore
  produce different `:nonce` values, so `PropertyDamage.audit/2` MUST reject a
  model using it. This is the failing-first RED proof that the audit catches
  impurity (DR-037).
  """
  @behaviour PropertyDamage.Command

  defstruct [:nonce]

  @impl true
  def generator(_overrides) do
    # Contract violation on purpose: unique_integer is monotonic per VM, so it
    # differs across two realizations of the same seed.
    StreamData.constant(%{nonce: System.unique_integer([:monotonic, :positive])})
  end
end

defmodule PropertyDamage.Test.Audit.ImpureGeneratorModel do
  @moduledoc """
  Model whose only command has an impure generator. `PropertyDamage.audit/2`
  returns `{:error, ...}` on it — the RED fixture for DR-037.
  """
  @behaviour PropertyDamage.Model
  @behaviour PropertyDamage.Model.Simulator

  alias PropertyDamage.Test.Audit.Commands.ImpureCreate
  alias PropertyDamage.Test.Audit.PassthroughProjection

  @impl true
  def commands, do: [ImpureCreate]

  @impl true
  def command_sequence_projection, do: PassthroughProjection

  @impl true
  def simulator, do: __MODULE__

  @impl PropertyDamage.Model.Simulator
  def simulate(_command, _state), do: []
end

defmodule PropertyDamage.Test.Audit.Commands.Stable do
  @moduledoc false
  @behaviour PropertyDamage.Command

  defstruct [:amount]

  @impl true
  def generator(overrides) do
    %{amount: StreamData.integer(1..100)}
    |> PropertyDamage.Generator.merge_overrides(overrides)
    |> StreamData.fixed_map()
  end
end

defmodule PropertyDamage.Test.Audit.ImpureSelectionModel do
  @moduledoc """
  Model whose `with:` override reads process-global state, changing the
  generated command's arguments across two same-seed generations. Proves the
  audit catches impurity in a `with:` predicate, not only in a raw generator.
  """
  @behaviour PropertyDamage.Model
  @behaviour PropertyDamage.Model.Simulator

  alias PropertyDamage.Test.Audit.Commands.Stable
  alias PropertyDamage.Test.Audit.PassthroughProjection

  @impl true
  def commands do
    [
      {Stable,
       with: fn _state ->
         # IMPURE: reads process-global state at generation time.
         %{amount: System.unique_integer([:monotonic, :positive])}
       end}
    ]
  end

  @impl true
  def command_sequence_projection, do: PassthroughProjection

  @impl true
  def simulator, do: __MODULE__

  @impl PropertyDamage.Model.Simulator
  def simulate(_command, _state), do: []
end

defmodule PropertyDamage.Test.Audit.Commands.MintSend do
  @moduledoc """
  PURE command using `mint_per_run/1`: the field carries a position-stamped
  marker at generation (a deterministic symbolic struct, DR-034/DR-036), so two
  same-seed generations are identical and the audit passes. The concrete value
  is derived only at execution — never resolved by the audit.
  """
  @behaviour PropertyDamage.Command

  defstruct [:request_id]

  @impl true
  def generator(_overrides) do
    StreamData.constant(%{request_id: PropertyDamage.mint_per_run(:uuid)})
  end
end

defmodule PropertyDamage.Test.Audit.MintModel do
  @moduledoc """
  Pure `mint_per_run`-using model. `PropertyDamage.audit/2` returns `:ok`:
  the mint marker is position-stamped and deterministic, so the plan is stable
  across two same-seed generations. Guards the DR-034/DR-036 foundation.
  """
  @behaviour PropertyDamage.Model
  @behaviour PropertyDamage.Model.Simulator

  alias PropertyDamage.Test.Audit.Commands.MintSend
  alias PropertyDamage.Test.Audit.PassthroughProjection

  @impl true
  def commands, do: [MintSend]

  @impl true
  def command_sequence_projection, do: PassthroughProjection

  @impl true
  def simulator, do: __MODULE__

  @impl PropertyDamage.Model.Simulator
  def simulate(_command, _state), do: []
end
