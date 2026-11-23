# Models, a system and adapters for the tests of plans with two lanes.
#
# The system is an account whose withdrawal is checked in one call and
# applied in a later one. The adapter yields between the two, so a step of
# the other lane can run in between, and it reports every part of a step it
# runs to a recorder process, so a test reads the order in which PD ran
# them. Each command carries an `id` drawn from a wide range, which names
# its step in that record.

defmodule PropertyDamage.Next.Test.Lanes do
  @moduledoc false
  # Helpers for reading what the lane fixtures recorded and for editing a
  # journal's schedule entries.

  @doc """
  The executions the lane adapters reported to the calling process, oldest
  first, each as `%{instance: ref, points: [{id, point}], teardowns: n}`.
  Reads and removes those messages from the mailbox.
  """
  def executions, do: executions([])

  defp executions(acc) do
    receive do
      {:lanes_setup, instance} ->
        executions([%{instance: instance, points: [], teardowns: 0} | acc])

      {:lanes_point, instance, id, point} ->
        acc |> update(instance, &%{&1 | points: &1.points ++ [{id, point}]}) |> executions()

      {:lanes_teardown, instance} ->
        acc |> update(instance, &%{&1 | teardowns: &1.teardowns + 1}) |> executions()
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp update(acc, instance, fun) do
    Enum.map(acc, fn
      %{instance: ^instance} = execution -> fun.(execution)
      execution -> execution
    end)
  end

  @doc "The keys the recording engine drew for the calling process, in order."
  def drawn_keys, do: drawn_keys([])

  defp drawn_keys(acc) do
    receive do
      {:lanes_engine_draw, key} -> drawn_keys([key | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  @doc "A field of a struct or map, read without naming it at compile time."
  def get(term, field), do: Map.fetch!(term, field)

  @doc """
  The journal's schedule entries as `%{step_key => [value, ...]}`, the
  values of each step in point order.
  """
  def schedule_of(journal) do
    journal.entries
    |> Enum.filter(&match?({{_step, :schedule, _point}, _entry}, &1))
    |> Enum.sort()
    |> Enum.group_by(fn {{step, :schedule, _point}, _entry} -> step end, fn {_key, entry} ->
      elem(entry, 1)
    end)
  end

  @doc """
  `journal` with the schedule entries of each step in `schedule` (a map of
  step key to a list of values, one per point) set to those values. Every
  entry must already exist and be an integer entry of PD's own engine; its
  range is kept.
  """
  def with_schedule(journal, schedule) do
    entries =
      for {step, values} <- schedule,
          {value, point} <- Enum.with_index(values, 1),
          reduce: journal.entries do
        entries ->
          key = {step, :schedule, point}
          {:integer, _stored, range} = Map.fetch!(entries, key)
          Map.put(entries, key, {:integer, value, range})
      end

    %{journal | entries: entries}
  end
end

defmodule PropertyDamage.Next.Test.Lanes.Account do
  @moduledoc false
  # An account with a balance. A withdrawal is checked against the balance
  # in one call and applied in another. Bug switches:
  #
  #   * `:race` - applying does not check again, so two withdrawals that
  #     were both checked before either applied can overdraw the account
  #   * `:full_twice` - with the check repeated, a withdrawal of the whole
  #     balance is taken twice, which overdraws the account in one lane
  #
  # With no bug, applying checks again and refuses an amount above the
  # balance.

  def start(bug), do: Agent.start_link(fn -> %{bug: bug, balance: 0} end)

  def stop(account) do
    if Process.alive?(account), do: Agent.stop(account)
    :ok
  end

  @doc "Adds `amount`; returns the new balance."
  def deposit(account, amount) do
    Agent.get_and_update(account, fn state ->
      balance = state.balance + amount
      {balance, %{state | balance: balance}}
    end)
  end

  @doc "`:ok` when `amount` is at most the balance now, else `:refused`."
  def check(account, amount),
    do: Agent.get(account, &if(amount <= &1.balance, do: :ok, else: :refused))

  @doc "Applies a checked withdrawal; returns `{:ok, balance}` or `:refused`."
  def apply_withdrawal(account, amount) do
    Agent.get_and_update(account, fn state ->
      case take(state, amount) do
        :refused -> {:refused, state}
        balance -> {{:ok, balance}, %{state | balance: balance}}
      end
    end)
  end

  defp take(%{bug: :race, balance: balance}, amount), do: balance - amount
  defp take(%{balance: balance}, amount) when amount > balance, do: :refused

  defp take(%{bug: :full_twice, balance: balance}, amount) when amount == balance,
    do: balance - 2 * amount

  defp take(%{balance: balance}, amount), do: balance - amount
end

defmodule PropertyDamage.Next.Test.Lanes.Events do
  @moduledoc false

  defmodule Deposited do
    @moduledoc false
    # `balance` is the account's balance after the deposit, as reported.
    defstruct [:id, :amount, :balance]
  end

  defmodule Withdrew do
    @moduledoc false
    # `balance` is the account's balance after the withdrawal, as reported.
    defstruct [:id, :amount, :balance]
  end

  defmodule Refused do
    @moduledoc false
    # The account refused a withdrawal that its lane's own state allowed.
    defstruct [:id, :amount]
  end
end

defmodule PropertyDamage.Next.Test.Lanes.Deposit do
  @moduledoc false
  use PropertyDamage.Next.Command

  defstruct [:id, :amount]

  def generator(_state, _opts), do: %{id: integer(1..1_000_000_000), amount: integer(1..100)}
end

defmodule PropertyDamage.Next.Test.Lanes.Withdraw do
  @moduledoc false
  # Withdraws at most the predicted balance.
  use PropertyDamage.Next.Command

  defstruct [:id, :amount]

  def generator(state, _opts),
    do: %{id: integer(1..1_000_000_000), amount: integer(1..state.balance)}
end

defmodule PropertyDamage.Next.Test.Lanes.Balance do
  @moduledoc false
  # The balance folded from the events, next to the balance the account
  # last reported. Neither may go below 0.
  use PropertyDamage.Model.Projection

  alias PropertyDamage.Next.Test.Lanes.Events.{Deposited, Withdrew}
  alias PropertyDamage.Next.Test.Lanes.Withdraw

  @impl true
  def init, do: %{balance: 0, reported: 0, deposited?: false}

  @impl true
  def apply(state, %Deposited{amount: amount, balance: reported}),
    do: %{state | balance: state.balance + amount, reported: reported, deposited?: true}

  def apply(state, %Withdrew{amount: amount, balance: reported}),
    do: %{state | balance: state.balance - amount, reported: reported}

  def apply(state, _event), do: state

  def funded?(state), do: state.balance > 0
  def unfunded?(state), do: not state.deposited?

  @check every: Withdraw
  def never_overdrawn(%{balance: balance, reported: reported}, _command) do
    (balance >= 0 and reported >= 0) or
      PropertyDamage.fail!("The account was overdrawn: balance #{balance}, reported #{reported}")
  end
end

defmodule PropertyDamage.Next.Test.Lanes.Simulator do
  @moduledoc false
  @behaviour PropertyDamage.Model.Simulator

  alias PropertyDamage.Next.Test.Lanes.{Deposit, Withdraw}
  alias PropertyDamage.Next.Test.Lanes.Events.{Deposited, Withdrew}

  @impl true
  def simulate(%Deposit{id: id, amount: amount}, state),
    do: [%Deposited{id: id, amount: amount, balance: state.balance + amount}]

  def simulate(%Withdraw{id: id, amount: amount}, state),
    do: [%Withdrew{id: id, amount: amount, balance: state.balance - amount}]

  def simulate(_command, _state), do: []
end

defmodule PropertyDamage.Next.Test.Lanes.Model do
  @moduledoc false
  # Deposits at any slot, withdrawals while the predicted balance is above 0.
  use PropertyDamage.Next.Model

  alias PropertyDamage.Next.StepSpec
  alias PropertyDamage.Next.Test.Lanes.{Deposit, Balance, Simulator, Withdraw}

  def steps,
    do:
      StepSpec.normalize([{Deposit, weight: 2}, {Withdraw, weight: 3, when: &Balance.funded?/1}])

  def simulator, do: Simulator
  def command_sequence_projection, do: Balance
  def check_projections, do: [Balance]
end

defmodule PropertyDamage.Next.Test.Lanes.OnceModel do
  @moduledoc false
  # One deposit, then only withdrawals. With one prefix slot and one slot
  # per lane, every plan deposits in the prefix and withdraws once in each
  # lane.
  use PropertyDamage.Next.Model

  alias PropertyDamage.Next.StepSpec
  alias PropertyDamage.Next.Test.Lanes.{Deposit, Balance, Simulator, Withdraw}

  def steps do
    StepSpec.normalize([
      {Deposit, when: &Balance.unfunded?/1},
      {Withdraw, when: &Balance.funded?/1}
    ])
  end

  def simulator, do: Simulator
  def command_sequence_projection, do: Balance
  def check_projections, do: [Balance]
end

defmodule PropertyDamage.Next.Test.Lanes.Adapter do
  @moduledoc false
  # Runs the lane models' commands against a fresh account per execution.
  # A deposit is one part. A withdrawal checks the balance in its first
  # part, yields, and applies in its last part; a withdrawal the check
  # refused still yields and then answers a refusal.
  #
  # Config keys:
  #
  #   * `:bug` - the account's bug switch (default `nil`)
  #   * `:yields` - how many times a withdrawal yields (default 1; 0 checks
  #     and applies in one part, as an adapter that never yields)
  #   * `:fail_id` - the id of a command whose first part answers
  #     `{:error, :seeded_failure}`
  #   * `:recorder` - a pid that receives `{:lanes_setup, instance}` when an
  #     execution starts, `{:lanes_point, instance, id, point}` as each part
  #     of a step starts, and `{:lanes_teardown, instance}` at teardown,
  #     `instance` being a reference unique to the execution
  @behaviour PropertyDamage.Next.Adapter

  alias PropertyDamage.Next.Test.Lanes.{Account, Deposit, Withdraw}
  alias PropertyDamage.Next.Test.Lanes.Events.{Deposited, Refused, Withdrew}

  @impl true
  def setup(config, _runtime) do
    {:ok, account} = Account.start(Map.get(config, :bug))
    instance = make_ref()
    notify(config, {:lanes_setup, instance})

    {:ok,
     %{account: account, instance: instance, config: config, yields: Map.get(config, :yields, 1)}}
  end

  @impl true
  def teardown(context) do
    notify(context.config, {:lanes_teardown, context.instance})
    Account.stop(context.account)
  end

  @impl true
  def execute(%{id: id} = command, _assigns, context) do
    point(context, id, 1)

    if Map.get(context.config, :fail_id) == id,
      do: {:error, :seeded_failure},
      else: run(command, context)
  end

  defp run(%Deposit{id: id, amount: amount}, context) do
    balance = Account.deposit(context.account, amount)
    {:ok, [%Deposited{id: id, amount: amount, balance: balance}]}
  end

  defp run(%Withdraw{id: id, amount: amount}, context) do
    withdrawal = %{id: id, amount: amount, checked: Account.check(context.account, amount)}
    rest(context, withdrawal, 2)
  end

  # The parts after the check: one per yield, the last one applying.
  defp rest(context, withdrawal, point) when point > context.yields + 1,
    do: finish(context, withdrawal)

  defp rest(context, withdrawal, point) do
    {:yield,
     fn ->
       point(context, withdrawal.id, point)
       rest(context, withdrawal, point + 1)
     end}
  end

  defp finish(_context, %{checked: :refused, id: id, amount: amount}),
    do: {:ok, [%Refused{id: id, amount: amount}]}

  defp finish(context, %{checked: :ok, id: id, amount: amount}) do
    case Account.apply_withdrawal(context.account, amount) do
      {:ok, balance} -> {:ok, [%Withdrew{id: id, amount: amount, balance: balance}]}
      :refused -> {:ok, [%Refused{id: id, amount: amount}]}
    end
  end

  defp point(context, id, point),
    do: notify(context.config, {:lanes_point, context.instance, id, point})

  defp notify(%{recorder: pid}, message) when is_pid(pid), do: send(pid, message)
  defp notify(_config, _message), do: :ok
end

defmodule PropertyDamage.Next.Test.Lanes.Ack.Alpha do
  @moduledoc false
  use PropertyDamage.Next.Command

  defstruct [:n]

  def generator(_state, _opts), do: %{n: integer(1..3)}
end

defmodule PropertyDamage.Next.Test.Lanes.Ack.Beta do
  @moduledoc false
  use PropertyDamage.Next.Command

  defstruct [:n]

  def generator(_state, _opts), do: %{n: integer(1..3)}
end

defmodule PropertyDamage.Next.Test.Lanes.Ack.Model do
  @moduledoc false
  # Two commands, each with an assign of its own that is always set:
  # `:alpha` beside Alpha, `:beta` beside Beta.
  use PropertyDamage.Next.Model

  alias PropertyDamage.Next.StepSpec
  alias PropertyDamage.Next.Test.Fixtures.{EmptyProjection, NullSimulator}
  alias PropertyDamage.Next.Test.Lanes.Ack.{Alpha, Beta}

  def steps do
    [Alpha, Beta]
    |> StepSpec.normalize()
    |> Enum.map(&StepSpec.assign(&1, assign_of(&1.command), StreamData.constant(true)))
  end

  def assign_of(Alpha), do: :alpha
  def assign_of(Beta), do: :beta

  def simulator, do: NullSimulator
  def command_sequence_projection, do: EmptyProjection
end

defmodule PropertyDamage.Next.Test.Lanes.Ack.Adapter do
  @moduledoc false
  # Each step yields once. Alpha acknowledges in its second part, Beta in
  # its first, so with Alpha in lane 1, Beta in lane 2 and the parts run as
  # Alpha 1, Beta 1, Alpha 2, Beta 2, each acknowledgment is made while the
  # other step is open.
  #
  # Config keys: `:mode` (`:own`, the default: each step acknowledges its
  # own assign; `:cross`: Alpha acknowledges `:beta`, which only Beta set)
  # and `:recorder` (as for `PropertyDamage.Next.Test.Lanes.Adapter`, with
  # the command module in place of the id).
  @behaviour PropertyDamage.Next.Adapter

  alias PropertyDamage.Next.Runtime
  alias PropertyDamage.Next.Test.Lanes.Ack.{Alpha, Beta}

  @impl true
  def setup(config, runtime) do
    instance = make_ref()
    notify(config, {:lanes_setup, instance})
    {:ok, %{runtime: runtime, config: config, instance: instance}}
  end

  @impl true
  def teardown(context), do: notify(context.config, {:lanes_teardown, context.instance})

  @impl true
  def execute(%Alpha{}, _assigns, context) do
    point(context, Alpha, 1)

    {:yield,
     fn ->
       point(context, Alpha, 2)
       :ok = Runtime.ack(context.runtime, alpha_ack(context.config))
       {:ok, []}
     end}
  end

  def execute(%Beta{}, _assigns, context) do
    point(context, Beta, 1)
    :ok = Runtime.ack(context.runtime, :beta)

    {:yield,
     fn ->
       point(context, Beta, 2)
       {:ok, []}
     end}
  end

  defp alpha_ack(%{mode: :cross}), do: :beta
  defp alpha_ack(_config), do: :alpha

  defp point(context, command, point),
    do: notify(context.config, {:lanes_point, context.instance, command, point})

  defp notify(%{recorder: pid}, message) when is_pid(pid), do: send(pid, message)
  defp notify(_config, _message), do: :ok
end

defmodule PropertyDamage.Next.Test.Lanes.RecordingEngine do
  @moduledoc false
  # PD's own engine, telling the calling process the key of every draw as
  # `{:lanes_engine_draw, key}`, so a test reads the draw order.
  @behaviour PropertyDamage.Next.Engine

  alias PropertyDamage.Next.Engine.Native

  @impl true
  def draw(journal, key, generator, seed) do
    send(self(), {:lanes_engine_draw, key})
    Native.draw(journal, key, generator, seed)
  end
end

defmodule PropertyDamage.Next.Test.Lanes.Peer do
  @moduledoc false
  # What a second VM computes from a saved journal: called there through
  # `:peer.call/5`, so it can only use modules on the shared code path.

  alias PropertyDamage.Corpus.{FireLog, Loader}
  alias PropertyDamage.Next
  alias PropertyDamage.Next.Journal

  @doc """
  Loads `binary` as a journal of `model`, rebuilds its plan and replays it
  against `adapter` with `config`. Returns the loaded journal, the plan and
  the replay's result.
  """
  def replay(binary, model, adapter, config, engine) do
    journal = Journal.from_binary(binary, model: model)
    plan = Next.plan(model, journal, engine: engine)

    replayed =
      Next.replay(binary, model: model, adapter: adapter, config: config, engine: engine)

    %{journal: journal, plan: plan, replayed: replayed}
  end

  @doc """
  As `replay/5`, for the corpus entry `name` of the directory `dir`, with
  the entry's bug on and a fresh fire log.
  """
  def replay_entry(dir, name, binary, engine) do
    Logger.put_process_level(self(), :error)
    {:ok, [entry]} = Loader.load(dir, [name])
    {:ok, log} = FireLog.start_link()

    try do
      replay(binary, entry.model, entry.adapter, %{bug: entry.bug, fire_log: log}, engine)
    after
      FireLog.stop(log)
    end
  end
end
