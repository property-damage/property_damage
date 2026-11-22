# A payment system with a seeded bug behind a switch, for the shrinker's
# worked example and the corpus engine's tests: a refund that empties a
# payment above 100 is accepted, but its credit is never applied. The
# smallest failing plan pays 101 and refunds all 101 of it.
#
# The system records each run of the buggy path in a
# `PropertyDamage.Corpus.FireLog`, per system instance, as the corpus
# harness expects.

defmodule PropertyDamage.Next.Test.FullRefund.System do
  @moduledoc false
  use Agent

  alias PropertyDamage.Corpus.FireLog

  def start(opts) do
    log = Keyword.get(opts, :fire_log)
    instance = FireLog.started(log)

    Agent.start_link(fn ->
      %{bug: Keyword.get(opts, :bug), log: log, instance: instance, next: 1, payments: %{}}
    end)
  end

  def stop(system), do: Agent.stop(system)

  def pay(system, amount) do
    Agent.get_and_update(system, fn state ->
      id = "pay_#{state.next}"
      payment = %{amount: amount, balance: amount}
      {id, %{state | next: state.next + 1, payments: Map.put(state.payments, id, payment)}}
    end)
  end

  @doc "Refunds `amount` of payment `id`; returns `{:ok, balance}` or `{:error, reason}`."
  def refund(system, id, amount) do
    Agent.get_and_update(system, fn state ->
      case Map.fetch(state.payments, id) do
        :error -> {{:error, :unknown_payment}, state}
        {:ok, %{balance: balance}} when amount > balance -> {{:error, :exceeds_balance}, state}
        {:ok, payment} -> credit(state, id, payment, amount)
      end
    end)
  end

  defp credit(%{bug: :lost_full_refund} = state, _id, payment, amount)
       when payment.amount > 100 and amount == payment.balance do
    FireLog.fired(state.log, state.instance)
    {{:ok, payment.balance}, state}
  end

  defp credit(state, id, payment, amount) do
    payment = %{payment | balance: payment.balance - amount}
    {{:ok, payment.balance}, put_in(state, [:payments, id], payment)}
  end
end

defmodule PropertyDamage.Next.Test.FullRefund.Events do
  @moduledoc false

  defmodule Paid do
    @moduledoc false
    import PropertyDamage, only: [external: 0]
    defstruct [:amount, payment: external()]
  end

  defmodule Refunded do
    @moduledoc false
    # `balance` is the payment's balance after the refund, as reported.
    defstruct [:payment, :amount, :balance]
  end
end

defmodule PropertyDamage.Next.Test.FullRefund.Pay do
  @moduledoc false
  use PropertyDamage.Next.Command

  defstruct [:amount]

  def generator(_state, _opts), do: %{amount: integer(1..1_000)}
end

defmodule PropertyDamage.Next.Test.FullRefund.Refund do
  @moduledoc false
  # Refunds part or all of a payment that still has a balance.
  use PropertyDamage.Next.Command

  defstruct [:payment, :amount]

  def possible?(state), do: refundable(state) != []

  @doc "Payments with a balance above 0, in the order they were made."
  def refundable(state), do: for(id <- state.order, state.payments[id].expected > 0, do: id)

  def generator(state, _opts) do
    %{
      payment: member_of(refundable(state)),
      amount: from(:payment, fn id -> integer(1..state.payments[id].expected) end)
    }
  end
end

defmodule PropertyDamage.Next.Test.FullRefund.Memo do
  @moduledoc false
  # A note whose length limit is drawn first: the text is a StreamData
  # generator returned by a from/2 function, which PD's own engine draws with
  # a warning.
  use PropertyDamage.Next.Command

  defstruct [:limit, :text]

  def generator(_state, _opts) do
    %{
      limit: integer(1..8),
      text: from(:limit, fn limit -> StreamData.string(:alphanumeric, max_length: limit) end)
    }
  end
end

defmodule PropertyDamage.Next.Test.FullRefund.Projection do
  @moduledoc false
  # Each payment's predicted balance next to the balance the system reports;
  # after every refund the two must agree.
  use PropertyDamage.Model.Projection

  alias PropertyDamage.Next.Test.FullRefund.Events.{Paid, Refunded}
  alias PropertyDamage.Next.Test.FullRefund.Refund

  @impl true
  def init, do: %{payments: %{}, order: [], last: nil}

  @impl true
  def apply(state, %Paid{payment: id, amount: amount}) do
    %{
      state
      | payments: Map.put(state.payments, id, %{expected: amount, reported: amount}),
        order: state.order ++ [id]
    }
  end

  def apply(state, %Refunded{payment: id, amount: amount, balance: balance}) do
    state
    |> update_in([:payments, id], &%{expected: &1.expected - amount, reported: balance})
    |> Map.put(:last, id)
  end

  def apply(state, _event), do: state

  @check every: Refund
  def balance_matches(state, _command) do
    %{expected: expected, reported: reported} = state.payments[state.last]

    reported == expected or
      PropertyDamage.fail!("The system reports #{reported}, the model expects #{expected}")
  end
end

defmodule PropertyDamage.Next.Test.FullRefund.Simulator do
  @moduledoc false
  @behaviour PropertyDamage.Model.Simulator

  alias PropertyDamage.Next.Test.FullRefund.Events.{Paid, Refunded}
  alias PropertyDamage.Next.Test.FullRefund.{Pay, Refund}

  @impl true
  def simulate(%Pay{amount: amount}, _state), do: [%Paid{amount: amount}]

  def simulate(%Refund{payment: id, amount: amount}, state),
    do: [%Refunded{payment: id, amount: amount, balance: state.payments[id].expected - amount}]

  def simulate(_command, _state), do: []
end

defmodule PropertyDamage.Next.Test.FullRefund.Model do
  @moduledoc false
  use PropertyDamage.Next.Model

  alias PropertyDamage.Next.StepSpec
  alias PropertyDamage.Next.Test.FullRefund.{Pay, Projection, Refund, Simulator}

  def steps,
    do: StepSpec.normalize([{Pay, weight: 2}, {Refund, weight: 3, when: &Refund.possible?/1}])

  def simulator, do: Simulator
  def command_sequence_projection, do: Projection
  def check_projections, do: [Projection]
end

defmodule PropertyDamage.Next.Test.FullRefund.MemoModel do
  @moduledoc false
  # The same model with a memo command, whose text is a dependent StreamData
  # generator.
  use PropertyDamage.Next.Model

  alias PropertyDamage.Next.StepSpec
  alias PropertyDamage.Next.Test.FullRefund.{Memo, Model}

  def steps, do: Model.steps() ++ StepSpec.normalize([Memo])
  def simulator, do: Model.simulator()
  def command_sequence_projection, do: Model.command_sequence_projection()
  def check_projections, do: Model.check_projections()
end

defmodule PropertyDamage.Next.Test.FullRefund.Adapter do
  @moduledoc false
  # Runs the commands against a fresh system per execution, started with the
  # config's `:bug` and `:fire_log`, as the corpus harness passes them.
  #
  # With `spare_instance: true` in the config, teardown also starts a spare
  # system instance that runs nothing, as a pool that keeps one warm system
  # would. The most recently started instance is then never the one that
  # ran the plan.
  @behaviour PropertyDamage.Next.Adapter

  alias PropertyDamage.Next.Test.FullRefund.Events.{Paid, Refunded}
  alias PropertyDamage.Next.Test.FullRefund.{Pay, Refund, System}

  @impl true
  def setup(config, _runtime) do
    {:ok, system} = System.start(bug: config[:bug], fire_log: config[:fire_log])
    {:ok, %{system: system, config: config}}
  end

  @impl true
  def teardown(%{system: system, config: config}) do
    if Process.alive?(system), do: System.stop(system)

    if config[:spare_instance] do
      {:ok, spare} = System.start(bug: config[:bug], fire_log: config[:fire_log])
      System.stop(spare)
    end

    :ok
  end

  @impl true
  def execute(%Pay{amount: amount}, _assigns, %{system: system}) do
    id = System.pay(system, amount)
    {:ok, [%Paid{payment: id, amount: amount}]}
  end

  def execute(%Refund{payment: id, amount: amount}, _assigns, %{system: system}) do
    case System.refund(system, id, amount) do
      {:ok, balance} -> {:ok, [%Refunded{payment: id, amount: amount, balance: balance}]}
      {:error, reason} -> {:error, reason}
    end
  end

  def execute(_command, _assigns, _context), do: {:ok, []}
end

defmodule PropertyDamage.Next.Test.FullRefund.SpareAdapter do
  @moduledoc false
  # The adapter above with a spare system instance started after every
  # execution, for a harness that passes only `:bug` and `:fire_log`.
  @behaviour PropertyDamage.Next.Adapter

  alias PropertyDamage.Next.Test.FullRefund.Adapter

  @impl true
  def setup(config, runtime),
    do: config |> Map.put(:spare_instance, true) |> Adapter.setup(runtime)

  @impl true
  def teardown(context), do: Adapter.teardown(context)

  @impl true
  def execute(command, assigns, context), do: Adapter.execute(command, assigns, context)
end
