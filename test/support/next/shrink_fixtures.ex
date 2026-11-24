# Small models and systems for the shrinker's tests. Each command module
# draws the kinds of values one test needs; the adapters fail on a condition
# the test passes in its config, and tell a recorder process what they
# executed, so a test can count the plans a shrink ran and read the values
# each one tried.

defmodule PropertyDamage.Next.Test.Shrink.Adapter do
  @moduledoc false
  # A system with no behavior of its own: every command answers no events.
  #
  # Config keys: `:fails?` (a function of the command and the commands the
  # same execution ran before it; when it answers true the command fails
  # with `{:error, :seeded_bug}`) and `:recorder` (a pid that receives
  # `{:shrink_setup, instance}` when an execution starts and
  # `{:shrink_executed, instance, command}` for each command, `instance`
  # being a reference unique to the execution).
  @behaviour PropertyDamage.Next.Adapter

  @impl true
  def setup(config, _runtime) do
    {:ok, history} = Agent.start_link(fn -> [] end)
    instance = make_ref()
    notify(config, {:shrink_setup, instance})
    {:ok, %{history: history, instance: instance, config: config}}
  end

  @impl true
  def teardown(%{history: history}) do
    if Process.alive?(history), do: Agent.stop(history)
    :ok
  end

  @impl true
  def execute(command, _assigns, context) do
    earlier = Agent.get_and_update(context.history, &{Enum.reverse(&1), [command | &1]})
    notify(context.config, {:shrink_executed, context.instance, command})
    fails? = Map.get(context.config, :fails?, fn _command, _earlier -> false end)
    if fails?.(command, earlier), do: {:error, :seeded_bug}, else: {:ok, []}
  end

  defp notify(%{recorder: pid}, message) when is_pid(pid), do: send(pid, message)
  defp notify(_config, _message), do: :ok
end

defmodule PropertyDamage.Next.Test.Shrink.Amount do
  @moduledoc false
  # One integer over a wide range.
  use PropertyDamage.Next.Command

  defstruct [:amount]

  def generator(_state, _opts), do: %{amount: integer(1..1_000)}
end

defmodule PropertyDamage.Next.Test.Shrink.Split do
  @moduledoc false
  # Lowering `cut` widens the range of `rest`: a value of `rest` that sat on
  # its upper bound no longer does once `cut` goes down.
  use PropertyDamage.Next.Command

  defstruct [:cut, :rest]

  def generator(_state, _opts),
    do: %{cut: integer(1..100), rest: from(:cut, fn cut -> integer(1..(101 - cut)) end)}
end

defmodule PropertyDamage.Next.Test.Shrink.Five do
  @moduledoc false
  # Five independent integers, for a failure that needs only some of them.
  use PropertyDamage.Next.Command

  defstruct [:a, :b, :c, :d, :e]

  def generator(_state, _opts) do
    %{
      a: integer(1..100),
      b: integer(1..100),
      c: integer(1..100),
      d: integer(1..100),
      e: integer(1..100)
    }
  end
end

defmodule PropertyDamage.Next.Test.Shrink.Note do
  @moduledoc false
  # A value drawn by StreamData.
  use PropertyDamage.Next.Command

  defstruct [:text]

  def generator(_state, _opts), do: %{text: string(:alphanumeric, max_length: 12)}
end

# --- A store: integer, member and StreamData fields, and a dependent field
# that reads the predicted state.

defmodule PropertyDamage.Next.Test.Shrink.Stock.Stocked do
  @moduledoc false
  defstruct [:key, :size]
end

defmodule PropertyDamage.Next.Test.Shrink.Stock.Put do
  @moduledoc false
  use PropertyDamage.Next.Command

  defstruct [:key, :size, :tag]

  def keys, do: [:a, :b, :c]

  def generator(_state, _opts) do
    %{
      key: member_of(keys()),
      size: integer(1..50),
      tag: string(:alphanumeric, max_length: 5)
    }
  end
end

defmodule PropertyDamage.Next.Test.Shrink.Stock.Take do
  @moduledoc false
  # Takes up to the size the predicted state holds for a stocked key.
  use PropertyDamage.Next.Command

  defstruct [:key, :count]

  def possible?(state), do: map_size(state) > 0

  @doc "The keys a take may name, in a fixed order."
  def stocked(state), do: state |> Map.keys() |> Enum.sort()

  def generator(state, _opts) do
    %{
      key: member_of(stocked(state)),
      count: from(:key, fn key -> integer(1..Map.fetch!(state, key)) end)
    }
  end
end

defmodule PropertyDamage.Next.Test.Shrink.Stock.Projection do
  @moduledoc false
  # The predicted state: the size of the last put of each key.
  use PropertyDamage.Model.Projection

  alias PropertyDamage.Next.Test.Shrink.Stock.Stocked

  @impl true
  def init, do: %{}

  @impl true
  def apply(state, %Stocked{key: key, size: size}), do: Map.put(state, key, size)
  def apply(state, _event), do: state
end

defmodule PropertyDamage.Next.Test.Shrink.Stock.Simulator do
  @moduledoc false
  @behaviour PropertyDamage.Model.Simulator

  alias PropertyDamage.Next.Test.Shrink.Stock.{Put, Stocked}

  @impl true
  def simulate(%Put{key: key, size: size}, _state), do: [%Stocked{key: key, size: size}]
  def simulate(_command, _state), do: []
end

defmodule PropertyDamage.Next.Test.Shrink.Stock.Model do
  @moduledoc false
  use PropertyDamage.Next.Model

  alias PropertyDamage.Next.StepSpec
  alias PropertyDamage.Next.Test.Shrink.Stock.{Projection, Put, Simulator, Take}

  def steps,
    do: StepSpec.normalize([{Put, weight: 2}, {Take, weight: 3, when: &Take.possible?/1}])

  def simulator, do: Simulator
  def command_sequence_projection, do: Projection
end

# --- A till whose fifth refund of one payment is lost: payments the system
# mints, refunds that name them, and unrelated pings.

defmodule PropertyDamage.Next.Test.Shrink.Till.Events do
  @moduledoc false

  defmodule Paid do
    @moduledoc false
    import PropertyDamage, only: [external: 0]
    defstruct [:amount, payment: external()]
  end

  defmodule Refunded do
    @moduledoc false
    defstruct [:payment]
  end
end

defmodule PropertyDamage.Next.Test.Shrink.Till.Pay do
  @moduledoc false
  use PropertyDamage.Next.Command

  defstruct [:amount]

  def generator(_state, _opts), do: %{amount: integer(1..100)}
end

defmodule PropertyDamage.Next.Test.Shrink.Till.Refund do
  @moduledoc false
  use PropertyDamage.Next.Command

  defstruct [:payment]

  def possible?(state), do: state.payments != []

  def generator(state, _opts), do: %{payment: member_of(state.payments)}
end

defmodule PropertyDamage.Next.Test.Shrink.Till.Ping do
  @moduledoc false
  use PropertyDamage.Next.Command

  defstruct [:n]

  def generator(_state, _opts), do: %{n: integer(1..100)}
end

defmodule PropertyDamage.Next.Test.Shrink.Till.Projection do
  @moduledoc false
  use PropertyDamage.Model.Projection

  alias PropertyDamage.Next.Test.Shrink.Till.Events.Paid

  @impl true
  def init, do: %{payments: []}

  @impl true
  def apply(state, %Paid{payment: id}), do: %{state | payments: state.payments ++ [id]}
  def apply(state, _event), do: state
end

defmodule PropertyDamage.Next.Test.Shrink.Till.Simulator do
  @moduledoc false
  @behaviour PropertyDamage.Model.Simulator

  alias PropertyDamage.Next.Test.Shrink.Till.Events.{Paid, Refunded}
  alias PropertyDamage.Next.Test.Shrink.Till.{Pay, Refund}

  @impl true
  def simulate(%Pay{amount: amount}, _state), do: [%Paid{amount: amount}]
  def simulate(%Refund{payment: id}, _state), do: [%Refunded{payment: id}]
  def simulate(_command, _state), do: []
end

defmodule PropertyDamage.Next.Test.Shrink.Till.Model do
  @moduledoc false
  use PropertyDamage.Next.Model

  alias PropertyDamage.Next.StepSpec
  alias PropertyDamage.Next.Test.Shrink.Till.{Pay, Ping, Projection, Refund, Simulator}

  def steps do
    StepSpec.normalize([
      {Pay, weight: 1},
      {Refund, weight: 4, when: &Refund.possible?/1},
      {Ping, weight: 2}
    ])
  end

  def simulator, do: Simulator
  def command_sequence_projection, do: Projection
end

defmodule PropertyDamage.Next.Test.Shrink.Till.Adapter do
  @moduledoc false
  # The till's system, one per execution. Config keys: `:bug` (true makes
  # the fifth refund of one payment fail with `{:error, :fifth_refund}`) and
  # `:recorder` (a pid that receives `{:till_setup, instance}` per
  # execution).
  @behaviour PropertyDamage.Next.Adapter

  alias PropertyDamage.Next.Test.Shrink.Till.Events.{Paid, Refunded}
  alias PropertyDamage.Next.Test.Shrink.Till.{Pay, Refund}

  @impl true
  def setup(config, _runtime) do
    {:ok, system} = Agent.start_link(fn -> %{next: 1, refunds: %{}} end)
    if is_pid(config[:recorder]), do: send(config[:recorder], {:till_setup, make_ref()})
    {:ok, %{system: system, bug: Map.get(config, :bug, false)}}
  end

  @impl true
  def teardown(%{system: system}) do
    if Process.alive?(system), do: Agent.stop(system)
    :ok
  end

  @impl true
  def execute(%Pay{amount: amount}, _assigns, %{system: system}) do
    id =
      Agent.get_and_update(system, fn state ->
        id = "p#{state.next}"
        {id, %{state | next: state.next + 1, refunds: Map.put(state.refunds, id, 0)}}
      end)

    {:ok, [%Paid{payment: id, amount: amount}]}
  end

  def execute(%Refund{payment: id}, _assigns, %{system: system, bug: bug}) do
    count =
      Agent.get_and_update(system, fn state ->
        count = Map.fetch!(state.refunds, id) + 1
        {count, %{state | refunds: Map.put(state.refunds, id, count)}}
      end)

    if bug and count == 5,
      do: {:error, :fifth_refund},
      else: {:ok, [%Refunded{payment: id}]}
  end

  def execute(_command, _assigns, _context), do: {:ok, []}
end

require PropertyDamage.Next.Test.Fixtures.Models

alias PropertyDamage.Next.Test.Fixtures, as: F
alias PropertyDamage.Next.Test.Shrink

F.Models.defmodel(Shrink.AmountModel, [Shrink.Amount])
F.Models.defmodel(Shrink.SplitModel, [Shrink.Split])
F.Models.defmodel(Shrink.NoteModel, [Shrink.Note])
F.Models.defmodel(Shrink.FiveModel, [Shrink.Five])
