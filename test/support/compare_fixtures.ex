defmodule PropertyDamage.Test.Compare do
  @moduledoc false
  # Fixtures for the boundary comparison tests (`@compare` observations).
  #
  # Projections that declare `@compare` are compiled at test runtime from
  # source text (`compile_all/1`, `compile/1`), so a test file still compiles
  # when the projection does not, and a compile failure becomes that test's
  # failure. Everything here uses only plain syntax.
  #
  # Messages `PayAdapter` and `StutterAdapter` send to `config.test_pid`:
  #
  #   {:setup, name}                 setup/1 ran
  #   {:executed, name, n, module}   execute/3 ran for the command numbered `n`
  #                                  (one message per call, retries included)

  import ExUnit.Assertions

  alias PropertyDamage.FailureReport.Formatter
  alias PropertyDamage.Generator

  # ==========================================================================
  # Events
  # ==========================================================================

  defmodule Paid do
    @moduledoc false
    defstruct [:n, :amount, :fee, :by]
  end

  defmodule Settled do
    @moduledoc false
    defstruct [:n, :amount]
  end

  defmodule Balance do
    @moduledoc false
    defstruct [:n, :value, :fresh]
  end

  # ==========================================================================
  # Commands
  # ==========================================================================

  defmodule Pay do
    @moduledoc false
    use PropertyDamage.Command
    defstruct [:n, :amount]

    @impl true
    def generator(overrides \\ %{}) do
      %{n: StreamData.constant(0), amount: StreamData.integer(1..9)}
      |> Generator.merge_overrides(overrides)
      |> StreamData.fixed_map()
    end
  end

  defmodule Read do
    @moduledoc false
    use PropertyDamage.Command,
      execution: :probe,
      settle: %{timeout_ms: 400, interval_ms: 10, backoff: :linear}

    defstruct [:n]

    @impl true
    def generator(overrides \\ %{}) do
      %{n: StreamData.constant(0)}
      |> Generator.merge_overrides(overrides)
      |> StreamData.fixed_map()
    end
  end

  # ==========================================================================
  # Projections without @compare
  # ==========================================================================

  defmodule Counter do
    @moduledoc false
    # The sequence projection: numbers the commands, so each command's `n` is
    # its root index in the generated sequence.
    @behaviour PropertyDamage.Model.Projection

    @impl true
    def init, do: %{count: 0}

    @impl true
    def apply(state, %Pay{}), do: %{state | count: state.count + 1}
    def apply(state, %Read{}), do: %{state | count: state.count + 1}
    def apply(state, _other), do: state
  end

  defmodule Plain do
    @moduledoc false
    # A projection with a check and no @compare.
    use PropertyDamage.Model.Projection

    @impl true
    def init, do: %{}

    @impl true
    def apply(state, _), do: state

    @check every: Settled
    def assert_settled_amount(_state, %Settled{amount: amount}) do
      if amount < 0, do: PropertyDamage.fail!("negative settlement", amount: amount)
      :ok
    end
  end

  # ==========================================================================
  # Commands lists and models
  # ==========================================================================

  @doc false
  # `:pay` generates only Pay commands. A list of modules is a script: the
  # command at root `i` is the `i`-th module, and the sequence ends with it.
  def commands(:pay), do: [{Pay, overrides: &number/1}]

  def commands(script) when is_list(script) do
    script
    |> Enum.uniq()
    |> Enum.map(fn module ->
      {module, when: fn state -> Enum.at(script, state.count) == module end, overrides: &number/1}
    end)
  end

  defp number(state), do: %{n: state.count}

  @doc false
  # Defines a model whose sequence projection is Counter and whose check
  # projections are `projections`.
  def define_model!(module, projections, commands \\ :pay) do
    support = __MODULE__

    quoted =
      quote do
        defmodule unquote(module) do
          @moduledoc false
          @behaviour PropertyDamage.Model

          @impl true
          def commands, do: unquote(support).commands(unquote(Macro.escape(commands)))

          @impl true
          def command_sequence_projection, do: unquote(Counter)

          @impl true
          def check_projections, do: unquote(projections)
        end
      end

    Code.compile_quoted(quoted)
    module
  end

  defmodule PayModel do
    @moduledoc false
    # Pay commands only and no @compare on any projection.
    @behaviour PropertyDamage.Model

    alias PropertyDamage.Test.Compare

    @impl true
    def commands, do: Compare.commands(:pay)

    @impl true
    def command_sequence_projection, do: PropertyDamage.Test.Compare.Counter
  end

  defmodule PlainModel do
    @moduledoc false
    # A check projection, and no @compare on any projection.
    @behaviour PropertyDamage.Model

    alias PropertyDamage.Test.Compare

    @impl true
    def commands, do: Compare.commands(:pay)

    @impl true
    def command_sequence_projection, do: PropertyDamage.Test.Compare.Counter

    @impl true
    def check_projections, do: [PropertyDamage.Test.Compare.Plain]
  end

  defmodule AcceptableModel do
    @moduledoc false
    # Lists Pay with the stutter key `acceptable_retry_events:`.
    @behaviour PropertyDamage.Model

    @impl true
    def commands, do: [{Pay, acceptable_retry_events: [Paid]}]

    @impl true
    def command_sequence_projection, do: PropertyDamage.Test.Compare.Counter
  end

  # ==========================================================================
  # Adapters
  # ==========================================================================

  defmodule PayAdapter do
    @moduledoc false
    # Config keys (all optional):
    #
    #   :name      label in messages and in Paid.by (so every target's events differ)
    #   :test_pid  receives the messages listed in the module doc above
    #   :fee       the fee in every Paid (default 1)
    #   :at        %{n => mode} for Pay number n; other Pays use :sync
    #   :reads     a list of read answers; read i answers the i-th entry, the
    #              last entry repeats. Default [{10, true}].
    #
    # Pay modes:
    #   :sync                       Paid and Settled in the answer
    #   {:sync, delta}              Settled carries amount + delta
    #   :never                      Paid only; nothing settles it
    #   {:after_ms, ms}             Paid; a poller delivers Settled `ms` later
    #   {:after_ms, ms, delta}      as above, Settled carries amount + delta
    #   {:gate, agent}              Paid; a poller delivers Settled once the
    #                               agent holds true
    #   {:hold_then_after, hold, ms} sleeps `hold` ms inside execute/3, then as
    #                               {:after_ms, ms}
    #
    # Read answers:
    #   {value, fresh}                     Balance{value, fresh}
    #   {:retries, k, {value, fresh}}      {:retry, _} k times, then the Balance
    use PropertyDamage.Adapter

    alias PropertyDamage.Test.Compare
    alias PropertyDamage.Test.Compare.{Balance, Paid, Pay, Read, Settled}

    @impl true
    def setup(config) do
      name = Map.get(config, :name, "pay")
      Compare.notify(config, {:setup, name})
      # Slot 1: completed reads; slot 2: retries answered in the current read.
      {:ok, Map.merge(config, %{name: name, read_counters: :atomics.new(2, [])})}
    end

    @impl true
    def teardown(_ctx), do: :ok

    @impl true
    def execute(%Pay{n: n, amount: amount}, ctx, runtime) do
      Compare.notify(ctx, {:executed, ctx.name, n, Pay})
      paid = %Paid{n: n, amount: amount, fee: Map.get(ctx, :fee, 1), by: ctx.name}
      settle(Map.get(Map.get(ctx, :at, %{}), n, :sync), paid, runtime)
    end

    def execute(%Read{n: n}, ctx, _runtime) do
      Compare.notify(ctx, {:executed, ctx.name, n, Read})
      reads = Map.get(ctx, :reads, [{10, true}])
      counters = ctx.read_counters
      done = :atomics.get(counters, 1)

      case Enum.at(reads, min(done, length(reads) - 1)) do
        {:retries, k, answer} ->
          if :atomics.add_get(counters, 2, 1) <= k do
            {:retry, :not_ready}
          else
            :atomics.put(counters, 2, 0)
            answer(counters, n, answer)
          end

        answer ->
          answer(counters, n, answer)
      end
    end

    defp answer(counters, n, {value, fresh}) do
      :atomics.add(counters, 1, 1)
      {:ok, [%Balance{n: n, value: value, fresh: fresh}]}
    end

    defp settle(:sync, paid, _runtime), do: {:ok, [paid, settled(paid, 0)]}
    defp settle({:sync, delta}, paid, _runtime), do: {:ok, [paid, settled(paid, delta)]}
    defp settle(:never, paid, _runtime), do: {:ok, [paid]}

    defp settle({:after_ms, ms}, paid, runtime), do: settle({:after_ms, ms, 0}, paid, runtime)

    defp settle({:after_ms, ms, delta}, paid, runtime) do
      deadline = System.monotonic_time(:millisecond) + ms

      deliver(runtime, settled(paid, delta), fn ->
        System.monotonic_time(:millisecond) >= deadline
      end)

      {:ok, [paid]}
    end

    defp settle({:gate, agent}, paid, runtime) do
      deliver(runtime, settled(paid, 0), fn -> Agent.get(agent, & &1) end)
      {:ok, [paid]}
    end

    defp settle({:hold_then_after, hold, ms}, paid, runtime) do
      Process.sleep(hold)
      settle({:after_ms, ms, 0}, paid, runtime)
    end

    defp settled(%Paid{n: n, amount: amount}, delta), do: %Settled{n: n, amount: amount + delta}

    defp deliver(runtime, event, ready?) do
      runtime.start_poller.(
        poll_fn: ready?,
        handler: fn
          true -> {:done, [event]}
          false -> :continue
        end,
        interval_ms: 5,
        timeout_ms: 5_000,
        on_timeout: :ignore
      )

      :ok
    end
  end

  defmodule StutterAdapter do
    @moduledoc false
    # Answers Pay with Paid{by: "first"}; a stutter retry answers
    # Paid{by: "retry"} under `retry: :different` and the same event under
    # `retry: :same` (the default).
    use PropertyDamage.Adapter

    alias PropertyDamage.Test.Compare
    alias PropertyDamage.Test.Compare.{Paid, Pay}

    @impl true
    def setup(config) do
      Compare.notify(config, {:setup, Map.get(config, :name, "stutter")})
      {:ok, config}
    end

    @impl true
    def teardown(_ctx), do: :ok

    @impl true
    def execute(%Pay{n: n, amount: amount}, ctx, runtime) do
      by =
        if PropertyDamage.Runtime.stuttering?(runtime) and Map.get(ctx, :retry) == :different,
          do: "retry",
          else: "first"

      {:ok, [%Paid{n: n, amount: amount, fee: 1, by: by}]}
    end
  end

  # ==========================================================================
  # Helpers
  # ==========================================================================

  @doc false
  def notify(%{test_pid: pid}, message) when is_pid(pid), do: send(pid, message)
  def notify(_config, _message), do: :ok

  @doc false
  # A remote predicate for `using:`.
  def same_settled?(reference, variant), do: reference.settled == variant.settled

  @doc false
  # A PayAdapter target named `name` that reports to the calling process.
  def target(name, config \\ %{}) do
    {PayAdapter, name: name, config: Map.merge(%{name: name, test_pid: self()}, config)}
  end

  @doc false
  def run(model, targets, extra \\ []) do
    [
      model: model,
      targets: targets,
      max_runs: 1,
      max_commands: 3,
      seed: 4_242,
      validate: false,
      shrink: false
    ]
    |> Keyword.merge(extra)
    |> PropertyDamage.run()
  end

  @doc false
  # Runs `fun` and returns `{elapsed_ms, result}`.
  def timed(fun) do
    started = System.monotonic_time(:millisecond)
    result = fun.()
    {System.monotonic_time(:millisecond) - started, result}
  end

  @doc false
  # Compiles `source` and returns `{:ok, modules}`, or `{:error, text}` with
  # the exception message and every diagnostic the compiler reported.
  def compile(source) do
    {result, diagnostics} =
      Code.with_diagnostics(fn ->
        try do
          {:ok, source |> Code.compile_string("compare_fixture.exs") |> Enum.map(&elem(&1, 0))}
        rescue
          exception -> {:error, Exception.message(exception)}
        end
      end)

    case result do
      {:ok, modules} ->
        {:ok, modules}

      {:error, message} ->
        errors = for %{severity: :error, message: m} <- diagnostics, do: m
        {:error, Enum.join([message | errors], "\n")}
    end
  end

  @doc false
  # Compiles every source of a `%{name => source}` map separately.
  def compile_all(sources), do: Map.new(sources, fn {name, source} -> {name, compile(source)} end)

  @doc false
  # The first module a compiled fixture defined; a compile failure fails the
  # calling test with the compiler's message.
  def fixture!(compiled, name) do
    case Map.fetch!(compiled, name) do
      {:ok, [module | _]} -> module
      {:error, text} -> flunk("fixture #{inspect(name)} did not compile:\n#{text}")
    end
  end

  @doc false
  # The exception `fun` raises; fails the test when it returns.
  def raised(fun) do
    result = fun.()
    flunk("expected an error, got: #{inspect(result, limit: 8)}")
  rescue
    exception in [ExUnit.AssertionError] -> reraise exception, __STACKTRACE__
    exception -> exception
  end

  @doc false
  def mismatch_module, do: Module.concat(PropertyDamage, ComparisonMismatch)

  @doc false
  def mismatch?(term), do: is_struct(term, mismatch_module()) and is_exception(term)

  @doc false
  # The terminal rendering of a failure report.
  def text(report), do: Formatter.format(report, :terminal, color: false)

  @doc false
  # The `compare_counts` entry of `key` on run stats or a failure report.
  def counts(stats_or_report, key) do
    stats_or_report |> Map.fetch!(:compare_counts) |> Map.fetch!(key)
  end

  @doc false
  # A field of a struct that may not declare it yet.
  def field(term, key), do: Map.fetch!(term, key)

  @doc false
  # Every message `{:executed, name, n, module}` in the mailbox, removed.
  def executions do
    receive do
      {:executed, _name, _n, _module} = message -> [message | executions()]
    after
      0 -> []
    end
  end

  @doc false
  def count(executions, name, n, module) do
    Enum.count(executions, &match?({:executed, ^name, ^n, ^module}, &1))
  end

  @doc false
  # The first term inside `term` (itself included) for which `match?` holds.
  def deep_find(term, match?) do
    if match?.(term) do
      term
    else
      term |> children() |> Enum.find_value(&deep_find(&1, match?))
    end
  end

  defp children(%{__struct__: _} = struct), do: struct |> Map.from_struct() |> Map.values()
  defp children(map) when is_map(map), do: Map.keys(map) ++ Map.values(map)
  defp children(list) when is_list(list), do: list
  defp children(tuple) when is_tuple(tuple), do: Tuple.to_list(tuple)
  defp children(_other), do: []
end
