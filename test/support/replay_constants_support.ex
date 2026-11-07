defmodule PropertyDamage.Test.ReplayConstants do
  @moduledoc """
  Statuses that only this module names. The model below does not list it, so
  in a fresh VM its atoms exist only once something loads it.
  """

  def statuses, do: [:replay_constant_open, :replay_constant_closed]
end

defmodule PropertyDamage.Test.ReplayConstants.Mark do
  @moduledoc false
  use PropertyDamage.Command

  alias PropertyDamage.Test.ReplayConstants

  defstruct [:status]

  @impl true
  def generator(overrides \\ %{}) do
    %{status: StreamData.member_of(ReplayConstants.statuses())}
    |> PropertyDamage.Generator.merge_overrides(overrides)
    |> StreamData.fixed_map()
  end
end

defmodule PropertyDamage.Test.ReplayConstants.Marked do
  @moduledoc false
  defstruct [:status]
end

defmodule PropertyDamage.Test.ReplayConstants.State do
  @moduledoc false
  @behaviour PropertyDamage.Model.Projection

  @impl true
  def init, do: %{}

  @impl true
  def apply(state, _event), do: state
end

defmodule PropertyDamage.Test.ReplayConstants.Check do
  @moduledoc false
  use PropertyDamage.Model.Projection

  @impl true
  def init, do: %{}

  @impl true
  def apply(state, _event), do: state

  @check every: PropertyDamage.Test.ReplayConstants.Marked
  def no_marks(_state, _event), do: PropertyDamage.fail!("a mark was made")
end

defmodule PropertyDamage.Test.ReplayConstants.Adapter do
  @moduledoc false
  use PropertyDamage.Adapter

  alias PropertyDamage.Test.ReplayConstants.{Mark, Marked}

  @impl true
  def setup(config), do: {:ok, config}

  @impl true
  def teardown(_context), do: :ok

  @impl true
  def execute(%Mark{status: status}, _context, _runtime), do: {:ok, [%Marked{status: status}]}
end

defmodule PropertyDamage.Test.ReplayConstants.Model do
  @moduledoc false
  use PropertyDamage.Model

  @impl true
  def commands, do: [PropertyDamage.Test.ReplayConstants.Mark]

  @impl true
  def command_sequence_projection, do: PropertyDamage.Test.ReplayConstants.State

  @impl true
  def check_projections, do: [PropertyDamage.Test.ReplayConstants.Check]
end
