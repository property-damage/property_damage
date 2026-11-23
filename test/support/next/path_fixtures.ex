# A small refund system for the tests of models that state paths: one
# command run as itself, or as finer commands that mean the same. A payment
# can be refunded in one refund or in two smaller ones. Behind the bug
# switch `:short_second_refund`, a refund of a payment that already had a
# refund credits one unit less than its amount, so a refund split in two
# credits less than the same refund made once. No check on one execution
# sees the bug; comparing the two executions does.
#
# The models are compiled with the test support, so a peer VM that shares
# the code paths loads them by name.

defmodule PropertyDamage.Next.Test.Paths.Events do
  @moduledoc false

  defmodule Paid do
    @moduledoc false
    import PropertyDamage, only: [external: 0]
    # The system mints the payment's id.
    defstruct [:amount, payment: external()]
  end

  defmodule Refunded do
    @moduledoc false
    # `credited` is what the system credited for the refund.
    defstruct [:payment, :amount, :credited]
  end

  defmodule Peeked do
    @moduledoc false
    defstruct [:refunded]
  end

  defmodule Settled do
    @moduledoc false
    # `refunded` is the system's refunded total at the settlement.
    defstruct [:refunded]
  end
end

defmodule PropertyDamage.Next.Test.Paths.Pay do
  @moduledoc false
  use PropertyDamage.Next.Command

  defstruct [:amount]

  def generator(_state, _opts), do: %{amount: integer(1..1_000)}
end

defmodule PropertyDamage.Next.Test.Paths.Refund do
  @moduledoc false
  # Refunds part or all of one earlier payment, up to its amount.
  use PropertyDamage.Next.Command

  defstruct [:payment, :amount]

  def possible?(state), do: state.payments != []

  def generator(state, _opts) do
    %{
      payment: member_of(state.payments),
      amount: from(:payment, fn payment -> integer(1..Map.fetch!(state.amounts, payment)) end)
    }
  end
end

defmodule PropertyDamage.Next.Test.Paths.Peek do
  @moduledoc false
  # A read that changes nothing. It appears only inside a path.
  use PropertyDamage.Next.Command

  defstruct []
end

defmodule PropertyDamage.Next.Test.Paths.Settle do
  @moduledoc false
  # Reports the system's refunded total; the only command that reveals it
  # to the settlement observation.
  use PropertyDamage.Next.Command

  defstruct []
end

defmodule PropertyDamage.Next.Test.Paths.Token do
  @moduledoc false
  # A command holding a value PD mints per execution.
  use PropertyDamage.Next.Command

  defstruct [:token]

  def generator(_state, _opts), do: %{token: mint_per_run({:hex, 8})}
end

defmodule PropertyDamage.Next.Test.Paths.Expansions do
  @moduledoc false
  # The paths of each listed command, the command itself first.

  alias PropertyDamage.Next.Gen
  alias PropertyDamage.Next.Test.Paths.{Pay, Peek, Refund, Token}

  @doc "The statement of the refund models: payments and refunds."
  def refunds, do: [{Pay, &pay_paths/2}, {Refund, &refund_paths/2}]

  @doc "A payment as itself, or followed by a read."
  def pay_paths(%Pay{} = pay, _state), do: [[pay], [pay, %Peek{}]]

  @doc """
  A refund of 2 or more as itself, or as two refunds whose first part is
  drawn from `1..amount - 1`; a refund of 1 only as itself.
  """
  def refund_paths(%Refund{amount: amount} = refund, _state)
      when is_integer(amount) and amount >= 2 do
    [
      [refund],
      {%{first: Gen.integer(1..(amount - 1))},
       fn %{first: first} -> [%{refund | amount: first}, %{refund | amount: amount - first}] end}
    ]
  end

  def refund_paths(%Refund{} = refund, _state), do: [[refund]]

  @doc "A token command as itself, or twice."
  def token_paths(%Token{} = token, _state), do: [[token], [token, token]]
end

defmodule PropertyDamage.Next.Test.Paths.State do
  @moduledoc false
  # The predicted state generation reads: the payments in order and the
  # amount of each.
  use PropertyDamage.Model.Projection

  alias PropertyDamage.Next.Test.Paths.Events.Paid

  @impl true
  def init, do: %{payments: [], amounts: %{}}

  @impl true
  def apply(state, %Paid{payment: payment, amount: amount}),
    do: %{
      state
      | payments: state.payments ++ [payment],
        amounts: Map.put(state.amounts, payment, amount)
    }

  def apply(state, _event), do: state
end

defmodule PropertyDamage.Next.Test.Paths.Totals do
  @moduledoc false
  # The paid and credited totals one execution observed, compared after
  # every step.
  use PropertyDamage.Model.Projection

  alias PropertyDamage.Next.Test.Paths.Events.{Paid, Refunded}

  @impl true
  def init, do: %{paid: 0, refunded: 0}

  @impl true
  def apply(state, %Paid{amount: amount}), do: %{state | paid: state.paid + amount}

  def apply(state, %Refunded{credited: credited}),
    do: %{state | refunded: state.refunded + credited}

  def apply(state, _event), do: state

  @compare every: 1
  def totals(state, _root), do: state
end

defmodule PropertyDamage.Next.Test.Paths.Settlement do
  @moduledoc false
  # The refunded total as of the last settlement: a split refund shows here
  # only once a later step settles.
  use PropertyDamage.Model.Projection

  alias PropertyDamage.Next.Test.Paths.Events.Settled

  @impl true
  def init, do: %{settled: 0}

  @impl true
  def apply(state, %Settled{refunded: refunded}), do: %{state | settled: refunded}
  def apply(state, _event), do: state

  @compare every: 1
  def settled(state, _root), do: state.settled
end

defmodule PropertyDamage.Next.Test.Paths.PeekCheck do
  @moduledoc false
  # A check that fails at every read.
  use PropertyDamage.Model.Projection

  @impl true
  def init, do: %{}

  @impl true
  def apply(state, _event), do: state

  @check every: PropertyDamage.Next.Test.Paths.Peek
  def no_peek(_state, _command), do: PropertyDamage.fail!("a read ran")
end

defmodule PropertyDamage.Next.Test.Paths.Simulator do
  @moduledoc false
  @behaviour PropertyDamage.Model.Simulator

  alias PropertyDamage.Next.Test.Paths.Events.{Paid, Refunded}
  alias PropertyDamage.Next.Test.Paths.{Pay, Refund}

  @impl true
  def simulate(%Pay{amount: amount}, _state), do: [%Paid{amount: amount}]

  def simulate(%Refund{payment: payment, amount: amount}, _state),
    do: [%Refunded{payment: payment, amount: amount, credited: amount}]

  def simulate(_command, _state), do: []
end

defmodule PropertyDamage.Next.Test.Paths.System do
  @moduledoc false
  # The refund system, one per execution. It counts the commands it executed.
  use Agent

  def start(bug),
    do: Agent.start_link(fn -> %{bug: bug, next: 1, payments: %{}, refunded: 0, executed: 0} end)

  def stop(system), do: Agent.stop(system)

  def executed(system), do: Agent.get(system, & &1.executed)

  def pay(system, amount) do
    update(system, fn state ->
      id = "p#{state.next}"
      payments = Map.put(state.payments, id, %{amount: amount, refunds: 0})
      {id, %{state | next: state.next + 1, payments: payments}}
    end)
  end

  @doc "Refunds `amount` of payment `id`; returns `{:ok, credited}` or `{:error, reason}`."
  def refund(system, id, amount) do
    update(system, fn state ->
      case Map.fetch(state.payments, id) do
        :error ->
          {{:error, {:unknown_payment, id}}, state}

        {:ok, payment} ->
          credited = credited(state.bug, payment, amount)
          payments = Map.put(state.payments, id, %{payment | refunds: payment.refunds + 1})
          {{:ok, credited}, %{state | payments: payments, refunded: state.refunded + credited}}
      end
    end)
  end

  def refunded(system), do: update(system, &{&1.refunded, &1})

  defp credited(:short_second_refund, %{refunds: refunds}, amount) when refunds > 0,
    do: amount - 1

  defp credited(_bug, _payment, amount), do: amount

  defp update(system, fun) do
    Agent.get_and_update(system, fn state ->
      {reply, state} = fun.(state)
      {reply, %{state | executed: state.executed + 1}}
    end)
  end
end

defmodule PropertyDamage.Next.Test.Paths.Adapter do
  @moduledoc false
  # Runs the refund commands against a fresh system per execution.
  #
  # Config keys:
  #
  #   * `:bug` - passed to the system (`:short_second_refund` or nil)
  #   * `:recorder` - a pid that receives `{:paths_setup, instance}` at each
  #     setup, `{:paths_executed, instance, command, assigns, result}` for
  #     each call of `execute/3`, and `{:paths_teardown, instance, executed}`
  #     at each teardown, `executed` being the number of commands that
  #     system ran. `instance` is a reference unique to the execution
  #   * `:ack` - true acknowledges every assign the step set
  #   * `:peek_error` - true makes every read answer `{:error, :peek_failed}`
  #   * `:failing_setup` - `{counter, n}`: the `n`th setup counted on the
  #     `:counters` reference `counter` answers `{:error, :no_system}`
  @behaviour PropertyDamage.Next.Adapter

  alias PropertyDamage.Next.Runtime
  alias PropertyDamage.Next.Test.Paths.Events.{Paid, Peeked, Refunded, Settled}
  alias PropertyDamage.Next.Test.Paths.{Pay, Peek, Refund, Settle, System}

  @impl true
  def setup(config, runtime) do
    if setup_fails?(config) do
      {:error, :no_system}
    else
      {:ok, system} = System.start(Map.get(config, :bug))
      instance = make_ref()
      notify(config, {:paths_setup, instance})
      {:ok, %{system: system, instance: instance, config: config, runtime: runtime}}
    end
  end

  @impl true
  def teardown(%{system: system, instance: instance, config: config}) do
    notify(config, {:paths_teardown, instance, System.executed(system)})
    System.stop(system)
  end

  @impl true
  def execute(command, assigns, context) do
    if context.config[:ack] do
      for {key, value} <- assigns, value, do: Runtime.ack(context.runtime, key)
    end

    result = call(command, context)
    notify(context.config, {:paths_executed, context.instance, command, assigns, result})
    result
  end

  defp call(%Pay{amount: amount}, %{system: system}) do
    id = System.pay(system, amount)
    {:ok, [%Paid{payment: id, amount: amount}]}
  end

  defp call(%Refund{payment: id, amount: amount}, %{system: system}) do
    case System.refund(system, id, amount) do
      {:ok, credited} -> {:ok, [%Refunded{payment: id, amount: amount, credited: credited}]}
      {:error, reason} -> {:error, reason}
    end
  end

  defp call(%Peek{}, %{config: %{peek_error: true}}), do: {:error, :peek_failed}
  defp call(%Peek{}, %{system: system}), do: {:ok, [%Peeked{refunded: System.refunded(system)}]}

  defp call(%Settle{}, %{system: system}),
    do: {:ok, [%Settled{refunded: System.refunded(system)}]}

  defp call(_command, _context), do: {:ok, []}

  defp setup_fails?(%{failing_setup: {counter, n}}) do
    :counters.add(counter, 1, 1)
    :counters.get(counter, 1) == n
  end

  defp setup_fails?(_config), do: false

  defp notify(%{recorder: pid}, message) when is_pid(pid), do: send(pid, message)
  defp notify(_config, _message), do: :ok
end

defmodule PropertyDamage.Next.Test.Paths.Layers do
  @moduledoc false
  alias PropertyDamage.Next.{Gen, StepSpec}

  @doc "An assign `:tag` on every spec, drawn from 1 to 5, so always set."
  def tag(spec), do: StepSpec.assign(spec, :tag, Gen.integer(1..5))
end

defmodule PropertyDamage.Next.Test.Paths.SplitModel do
  @moduledoc false
  # Payments and refunds, both listed with their paths; the totals are
  # compared after every step.
  use PropertyDamage.Next.Model

  alias PropertyDamage.Next.StepSpec
  alias PropertyDamage.Next.Test.Paths.{Expansions, Pay, Refund, Simulator, State, Totals}

  def steps,
    do: StepSpec.normalize([{Pay, weight: 1}, {Refund, weight: 2, when: &Refund.possible?/1}])

  def simulator, do: Simulator
  def command_sequence_projection, do: State
  def check_projections, do: [Totals]
  def expansions, do: Expansions.refunds()
end

defmodule PropertyDamage.Next.Test.Paths.PlainModel do
  @moduledoc false
  # The split model's specs with no paths and nothing compared.
  use PropertyDamage.Next.Model

  alias PropertyDamage.Next.Test.Paths.{SplitModel, State}

  def steps, do: SplitModel.steps()
  def simulator, do: SplitModel.simulator()
  def command_sequence_projection, do: State
end

defmodule PropertyDamage.Next.Test.Paths.QuietModel do
  @moduledoc false
  # The split model's specs and paths with nothing compared: both
  # executions run, and only a failure of either one fails the plan.
  use PropertyDamage.Next.Model

  alias PropertyDamage.Next.Test.Paths.{Expansions, SplitModel, State}

  def steps, do: SplitModel.steps()
  def simulator, do: SplitModel.simulator()
  def command_sequence_projection, do: State
  def expansions, do: Expansions.refunds()
end

defmodule PropertyDamage.Next.Test.Paths.AssignModel do
  @moduledoc false
  # The quiet model with an assign on every spec.
  use PropertyDamage.Next.Model

  alias PropertyDamage.Next.StepSpec
  alias PropertyDamage.Next.Test.Paths.{Expansions, Layers, SplitModel, State}

  def steps, do: StepSpec.transform(SplitModel.steps(), &Layers.tag/1)
  def simulator, do: SplitModel.simulator()
  def command_sequence_projection, do: State
  def expansions, do: Expansions.refunds()
end

defmodule PropertyDamage.Next.Test.Paths.AssignPlainModel do
  @moduledoc false
  # The assign model with no paths and nothing compared.
  use PropertyDamage.Next.Model

  alias PropertyDamage.Next.Test.Paths.{AssignModel, State}

  def steps, do: AssignModel.steps()
  def simulator, do: AssignModel.simulator()
  def command_sequence_projection, do: State
end

defmodule PropertyDamage.Next.Test.Paths.SettleModel do
  @moduledoc false
  # Payments and refunds listed with their paths, and settlements that are
  # not listed; only the settled total is compared.
  use PropertyDamage.Next.Model

  alias PropertyDamage.Next.StepSpec

  alias PropertyDamage.Next.Test.Paths.{
    Expansions,
    Pay,
    Refund,
    Settle,
    Settlement,
    Simulator,
    State
  }

  def steps do
    StepSpec.normalize([
      {Pay, weight: 1},
      {Refund, weight: 2, when: &Refund.possible?/1},
      {Settle, weight: 1, when: &Refund.possible?/1}
    ])
  end

  def simulator, do: Simulator
  def command_sequence_projection, do: State
  def check_projections, do: [Settlement]
  def expansions, do: Expansions.refunds()
end

defmodule PropertyDamage.Next.Test.Paths.PeekCheckModel do
  @moduledoc false
  # The quiet model with a check that fails at every read, which only a
  # payment's second path runs.
  use PropertyDamage.Next.Model

  alias PropertyDamage.Next.Test.Paths.{Expansions, PeekCheck, SplitModel, State}

  def steps, do: SplitModel.steps()
  def simulator, do: SplitModel.simulator()
  def command_sequence_projection, do: State
  def check_projections, do: [PeekCheck]
  def expansions, do: Expansions.refunds()
end

defmodule PropertyDamage.Next.Test.Paths.Recorded do
  @moduledoc false
  # Reads what the refund adapter told the test process, and the path of a
  # step without naming the field at compile time.

  alias PropertyDamage.Next.Placeholder
  alias PropertyDamage.Next.Test.Paths.{Pay, Totals}

  @doc "The adapter's messages still in the mailbox, in the order sent."
  def messages, do: drain([]) |> Enum.reverse()

  defp drain(acc) do
    receive do
      {:paths_setup, _} = message -> drain([message | acc])
      {:paths_executed, _, _, _, _} = message -> drain([message | acc])
      {:paths_teardown, _, _} = message -> drain([message | acc])
    after
      0 -> acc
    end
  end

  @doc """
  Every execution the adapter reported, in setup order, as
  `%{instance:, calls: [{command, assigns, result}], teardown: executed | nil}`.
  """
  def executions(messages \\ messages()) do
    {order, by} =
      Enum.reduce(messages, {[], %{}}, fn
        {:paths_setup, instance}, {order, by} ->
          {[instance | order],
           Map.put(by, instance, %{instance: instance, calls: [], teardown: nil})}

        {:paths_executed, instance, command, assigns, result}, {order, by} ->
          {order, update_in(by, [instance, :calls], &(&1 ++ [{command, assigns, result}]))}

        {:paths_teardown, instance, executed}, {order, by} ->
          {order, put_in(by, [instance, :teardown], executed)}
      end)

    order |> Enum.reverse() |> Enum.map(&Map.fetch!(by, &1))
  end

  @doc "The path of a step: `{index, commands}`, or nil."
  def path(step), do: Map.get(step, :path)

  @doc "The index of a step's picked path, or nil."
  def pick(step) do
    case path(step) do
      {index, _commands} -> index
      _none -> nil
    end
  end

  @doc "The commands of a step's picked path."
  def path_commands(step) do
    {_index, commands} = path(step)
    commands
  end

  @doc """
  `command` as the refund adapter receives it in an execution of `plan`:
  a payment placeholder becomes the id the system mints, `p<n>` for the
  `n`th payment step of the plan.
  """
  def concrete(command, plan) do
    pays = plan.steps |> Enum.filter(&match?(%Pay{}, &1.command)) |> Enum.map(& &1.key)

    command
    |> Map.from_struct()
    |> Enum.reduce(command, fn
      {field, %Placeholder{step: step}}, acc ->
        index = Enum.find_index(pays, &(&1 == step))
        Map.put(acc, field, "p#{index + 1}")

      _other, acc ->
        acc
    end)
  end

  @doc "The totals the events of `calls` fold to, as the totals observation reads them."
  def totals(calls) do
    Enum.reduce(calls, Totals.init(), fn
      {_command, _assigns, {:ok, events}}, state ->
        Enum.reduce(events, state, &Totals.apply(&2, &1))

      {_command, _assigns, _error}, state ->
        state
    end)
  end
end
