defmodule PropertyDamage.Test.LogFixtures do
  @moduledoc false
  # Fixtures for log lines in the failure report (DR-054): adapters that call
  # `PropertyDamage.log/2` and `PropertyDamage.Runtime.log/3`, the models they
  # run under, and the helpers that read a printed report's listing.
  #
  # Every module that calls `PropertyDamage.log/2` or `Runtime.log/3` is
  # compiled at test run time from the source text in `@source`
  # (`compile!/0`), so a test file still compiles while the macro is missing,
  # and the missing macro becomes the failure of the tests that need it. The
  # events, commands, projections, models and the `PlainAdapter` here use
  # only existing API and compile with the test suite.
  #
  # The logging adapter, `PropertyDamage.Test.LogFixtures.LogAdapter`, reads
  # its config (all keys optional):
  #
  #   :name          the target name, in every event's `by` and in its lines
  #   :test_pid      receives `{:logged, phase, name}` after a log call in
  #                  setup/1, execute/3 and teardown/1 returned, and
  #                  `{:runtime, runtime}` for the `:runtime` action
  #   :quiet         no line per execution (`"ran act <n> by <name>"`)
  #   :setup_log     setup/1 logs `"setup by <name>"` under the tag `:setup`
  #   :teardown_log  teardown/1 logs `"teardown by <name>"`
  #   :fail_setup    setup/1 answers `{:error, :no_backend}` after logging
  #   :server        setup/1 starts a `LogServer` for the `:server` action
  #   :owned_agent   setup/1 starts an Agent holding "owned", stopped in
  #                  teardown/1, for the `:owned_agent_fun` action
  #   :script        `%{n => [action]}`: what execute/3 does for Act `n`
  #                  before it answers
  #   :error_at      Act `n` answers `{:error, :refused}`
  #   :fail_at       Act `n` answers a Done that `Guard` fails on
  #   :skew_at       Act `n` answers a Done whose value is 2, not 1
  #   :spin_at       a Spin command answers `{:retry, _}` until its
  #                  attempt number reaches this value (default 3)
  #   :spin_detail   each Spin attempt logs a second line, `"spin detail <n>"`
  #   :spin_multiline  the first Spin attempt logs a two-line string first
  #
  # Actions (tags must be literal, so each tag set has its own action):
  #
  #   {:log, message}            PropertyDamage.log(message)
  #   {:log_http_url, message}   ... tags: [:http, :url]
  #   {:log_http, message}       ... tags: [:http]
  #   {:sleep, ms}
  #   {:inject, note}            runtime.inject.(%Injected{n, by, note})
  #   {:nested, message}         a Task that starts a Task that logs
  #   {:server, message}         the LogServer logs through Runtime.log/3
  #   :runtime                   sends the runtime to :test_pid
  #   {:agent_fun, name}         logs fn -> Agent.get(name, & &1) end
  #   :raising_fun               logs a function that raises
  #   :owned_agent_fun           logs a function reading the owned Agent
  #   :no_scope_server           calls an unlinked GenServer that logs
  #                              with no scope
  #   {:sentinel, parts}         joins `parts` with "-" into `text` and
  #                              logs `text`, `%{note: text}` and a
  #                              function returning `text`; the config
  #                              holds only the parts, so a file that holds
  #                              the joined text got it from a line
  #   {:value, term}             logs `term`
  #   {:capture, message}        runs `PropertyDamage.Log.capture/1` around a
  #                              log call and sends `{:captured, lines}` to
  #                              :test_pid

  import ExUnit.Assertions

  alias PropertyDamage.FailureReport.Formatter
  alias PropertyDamage.Generator

  # ==========================================================================
  # Events
  # ==========================================================================

  defmodule Done do
    @moduledoc false
    defstruct [:n, :by, value: 1, amount: 0, fail: false]
  end

  defmodule Injected do
    @moduledoc false
    defstruct [:n, :by, :note]
  end

  defmodule Prepared do
    @moduledoc false
    defstruct [:by]
  end

  defmodule Tidied do
    @moduledoc false
    defstruct [:by]
  end

  defmodule Parted do
    @moduledoc false
    defstruct [:root, :part, :by]
  end

  # ==========================================================================
  # Commands
  # ==========================================================================

  defmodule Act do
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

  defmodule Probe do
    @moduledoc false
    use PropertyDamage.Command,
      execution: :probe,
      settle: %{timeout_ms: 2_000, interval_ms: 5, backoff: :linear}

    defstruct [:n]

    @impl true
    def generator(overrides \\ %{}) do
      %{n: StreamData.constant(0)}
      |> Generator.merge_overrides(overrides)
      |> StreamData.fixed_map()
    end
  end

  defmodule Spin do
    @moduledoc false
    # A probe that retries without waiting, so a run can hold hundreds of
    # attempts.
    use PropertyDamage.Command,
      execution: :probe,
      settle: %{timeout_ms: 30_000, interval_ms: 0, backoff: :linear}

    defstruct [:n]

    @impl true
    def generator(overrides \\ %{}) do
      %{n: StreamData.constant(0)}
      |> Generator.merge_overrides(overrides)
      |> StreamData.fixed_map()
    end
  end

  defmodule Prepare do
    @moduledoc false
    use PropertyDamage.Command
    defstruct []

    @impl true
    def generator(overrides \\ %{}),
      do: %{} |> Generator.merge_overrides(overrides) |> StreamData.fixed_map()
  end

  defmodule Tidy do
    @moduledoc false
    use PropertyDamage.Command
    defstruct []

    @impl true
    def generator(overrides \\ %{}),
      do: %{} |> Generator.merge_overrides(overrides) |> StreamData.fixed_map()
  end

  defmodule Split do
    @moduledoc false
    use PropertyDamage.Command
    defstruct [:n]

    @impl true
    def generator(overrides \\ %{}) do
      %{n: StreamData.constant(0)}
      |> Generator.merge_overrides(overrides)
      |> StreamData.fixed_map()
    end
  end

  defmodule Part do
    @moduledoc false
    use PropertyDamage.Command
    defstruct [:root, :part]

    @impl true
    def generator(overrides \\ %{}) do
      %{root: StreamData.constant(0), part: StreamData.constant(0)}
      |> Generator.merge_overrides(overrides)
      |> StreamData.fixed_map()
    end
  end

  # ==========================================================================
  # Projections
  # ==========================================================================

  defmodule Counter do
    @moduledoc false
    # The sequence projection: numbers the roots, so each root's `n` is its
    # index in the generated sequence.
    @behaviour PropertyDamage.Model.Projection

    @impl true
    def init, do: %{count: 0}

    @impl true
    def apply(state, %PropertyDamage.Test.LogFixtures.Act{}),
      do: %{state | count: state.count + 1}

    def apply(state, %PropertyDamage.Test.LogFixtures.Probe{}),
      do: %{state | count: state.count + 1}

    def apply(state, %PropertyDamage.Test.LogFixtures.Split{}),
      do: %{state | count: state.count + 1}

    def apply(state, %PropertyDamage.Test.LogFixtures.Spin{}),
      do: %{state | count: state.count + 1}

    def apply(state, _other), do: state
  end

  defmodule Tally do
    @moduledoc false
    # The sum of the Done values, compared at every root: a target that
    # answers a skewed Done diverges there.
    use PropertyDamage.Model.Projection

    @impl true
    def init, do: %{total: 0, done: 0}

    @impl true
    def apply(s, %PropertyDamage.Test.LogFixtures.Done{value: v}),
      do: %{s | total: s.total + v, done: s.done + 1}

    def apply(s, _other), do: s

    @compare every: 1
    def total(s, _root), do: s.total
  end

  defmodule Guard do
    @moduledoc false
    # Fails on a Done marked `fail` and on a Parted leaf's second part.
    use PropertyDamage.Model.Projection

    @impl true
    def init, do: %{}

    @impl true
    def apply(state, _event), do: state

    @check every: PropertyDamage.Test.LogFixtures.Done
    def assert_done_ok(_state, %PropertyDamage.Test.LogFixtures.Done{fail: fail, n: n}) do
      not fail or PropertyDamage.fail!("done failed", n: n)
    end

    @check every: PropertyDamage.Test.LogFixtures.Parted
    def assert_first_part(_state, %PropertyDamage.Test.LogFixtures.Parted{part: part}) do
      part == 0 or PropertyDamage.fail!("second part", part: part)
    end
  end

  defmodule Cap do
    @moduledoc false
    # Fails once the Done amounts reach 15, so a failing run shrinks.
    use PropertyDamage.Model.Projection

    @impl true
    def init, do: %{sum: 0}

    @impl true
    def apply(s, %PropertyDamage.Test.LogFixtures.Done{amount: a}), do: %{s | sum: s.sum + a}
    def apply(s, _other), do: s

    @check every: PropertyDamage.Test.LogFixtures.Done
    def assert_under_cap(%{sum: sum}, _done) do
      sum < 15 or PropertyDamage.fail!("over the cap", sum: sum)
    end
  end

  # ==========================================================================
  # Models
  # ==========================================================================

  defmodule Model do
    @moduledoc false
    # Act roots, compared on Tally and checked by Guard.
    @behaviour PropertyDamage.Model

    @impl true
    def commands, do: [{PropertyDamage.Test.LogFixtures.Act, overrides: &number/1}]

    @impl true
    def command_sequence_projection, do: PropertyDamage.Test.LogFixtures.Counter

    @impl true
    def check_projections,
      do: [PropertyDamage.Test.LogFixtures.Tally, PropertyDamage.Test.LogFixtures.Guard]

    defp number(state), do: %{n: state.count}
  end

  defmodule CapModel do
    @moduledoc false
    # Act roots checked by Cap.
    @behaviour PropertyDamage.Model

    @impl true
    def commands, do: [{PropertyDamage.Test.LogFixtures.Act, overrides: &number/1}]

    @impl true
    def command_sequence_projection, do: PropertyDamage.Test.LogFixtures.Counter

    @impl true
    def check_projections, do: [PropertyDamage.Test.LogFixtures.Cap]

    defp number(state), do: %{n: state.count}
  end

  defmodule ProbeModel do
    @moduledoc false
    # Root 0 is a Probe, every later root an Act.
    @behaviour PropertyDamage.Model

    alias PropertyDamage.Test.LogFixtures.{Act, Probe}

    @impl true
    def commands do
      [
        {Probe, when: &(&1.count == 0), overrides: &number/1},
        {Act, when: &(&1.count > 0), overrides: &number/1}
      ]
    end

    @impl true
    def command_sequence_projection, do: PropertyDamage.Test.LogFixtures.Counter

    @impl true
    def check_projections, do: [PropertyDamage.Test.LogFixtures.Guard]

    defp number(state), do: %{n: state.count}
  end

  defmodule SpinModel do
    @moduledoc false
    # Root 0 is a Spin, every later root an Act.
    @behaviour PropertyDamage.Model

    alias PropertyDamage.Test.LogFixtures.{Act, Spin}

    @impl true
    def commands do
      [
        {Spin, when: &(&1.count == 0), overrides: &number/1},
        {Act, when: &(&1.count > 0), overrides: &number/1}
      ]
    end

    @impl true
    def command_sequence_projection, do: PropertyDamage.Test.LogFixtures.Counter

    @impl true
    def check_projections, do: [PropertyDamage.Test.LogFixtures.Guard]

    defp number(state), do: %{n: state.count}
  end

  defmodule PhaseModel do
    @moduledoc false
    # One setup command (Prepare), Split roots that always run as two Part
    # leaves, and one teardown command (Tidy). Guard fails on the first
    # Split's second part.
    @behaviour PropertyDamage.Model

    alias PropertyDamage.Test.LogFixtures
    alias PropertyDamage.Test.LogFixtures.{Part, Prepare, Split, Tidy}

    @impl true
    def commands, do: [{Split, overrides: &number/1}]

    @impl true
    def command_sequence_projection, do: PropertyDamage.Test.LogFixtures.Counter

    @impl true
    def check_projections,
      do: [PropertyDamage.Test.LogFixtures.Tally, PropertyDamage.Test.LogFixtures.Guard]

    @impl true
    def setup_each, do: [Prepare]

    @impl true
    def teardown_each, do: [Tidy]

    @impl true
    def expansions, do: [{Split, &LogFixtures.parts/2}]

    defp number(state), do: %{n: state.count}
  end

  @doc false
  # Split runs as its two parts.
  def parts(%Split{n: n}, _state) do
    [[{Part, overrides: %{root: n, part: 0}}, {Part, overrides: %{root: n, part: 1}}]]
  end

  # ==========================================================================
  # Answers shared by every adapter
  # ==========================================================================

  @doc false
  # The events a target answers for a command, the same whether it logs.
  def answer(%Act{n: n, amount: amount}, ctx) do
    if ctx[:error_at] == n do
      {:error, :refused}
    else
      done = %Done{
        n: n,
        by: ctx.name,
        amount: amount,
        value: if(ctx[:skew_at] == n, do: 2, else: 1),
        fail: ctx[:fail_at] == n
      }

      {:ok, [done]}
    end
  end

  def answer(%Probe{n: n}, ctx), do: {:ok, [%Done{n: n, by: ctx.name}]}
  def answer(%Spin{n: n}, ctx), do: {:ok, [%Done{n: n, by: ctx.name}]}
  def answer(%Prepare{}, ctx), do: {:ok, [%Prepared{by: ctx.name}]}
  def answer(%Tidy{}, ctx), do: {:ok, [%Tidied{by: ctx.name}]}

  def answer(%Part{root: root, part: part}, ctx),
    do: {:ok, [%Parted{root: root, part: part, by: ctx.name}]}

  defmodule PlainAdapter do
    @moduledoc false
    # Answers as LogAdapter does and logs nothing.
    use PropertyDamage.Adapter

    alias PropertyDamage.Test.LogFixtures

    @impl true
    def setup(config), do: {:ok, Map.put_new(config, :name, "alice")}

    @impl true
    def teardown(_ctx), do: :ok

    @impl true
    def execute(command, ctx, _runtime), do: LogFixtures.answer(command, ctx)
  end

  # ==========================================================================
  # Modules compiled from source text
  # ==========================================================================

  @source_file "log_fixtures_source.exs"

  @source ~S'''
  defmodule PropertyDamage.Test.LogFixtures.LogServer do
    @moduledoc false
    # Logs, on request, through the runtime it is handed.
    use GenServer

    def init(state), do: {:ok, state}

    def handle_call({:log, runtime, message}, _from, state) do
      :ok = PropertyDamage.Runtime.log(runtime, message, [])
      {:reply, :ok, state}
    end
  end

  defmodule PropertyDamage.Test.LogFixtures.NoScopeServer do
    @moduledoc false
    # Logs with no scope: a GenServer is not a Task, so it has no $callers.
    use GenServer
    require PropertyDamage

    def init(state), do: {:ok, state}

    def handle_call({:log, message}, _from, state) do
      PropertyDamage.log(message)
      {:reply, :ok, state}
    end
  end

  defmodule PropertyDamage.Test.LogFixtures.LogAdapter do
    @moduledoc false
    use PropertyDamage.Adapter
    require PropertyDamage

    alias PropertyDamage.Test.LogFixtures, as: F

    @impl true
    def setup(config) do
      name = Map.get(config, :name, "alice")

      if config[:setup_log] do
        PropertyDamage.log("setup by #{name}", tags: [:setup])
        notify(config, {:logged, :setup, name})
      end

      if config[:fail_setup] do
        {:error, :no_backend}
      else
        ctx =
          config
          |> Map.put(:name, name)
          |> Map.put(:attempts, :atomics.new(1, []))
          |> put_server(config[:server])
          |> put_owned(config[:owned_agent])

        {:ok, ctx}
      end
    end

    defp put_server(ctx, true) do
      {:ok, pid} = GenServer.start(F.LogServer, nil)
      Map.put(ctx, :server, pid)
    end

    defp put_server(ctx, _), do: ctx

    defp put_owned(ctx, true) do
      {:ok, pid} = Agent.start(fn -> "owned" end)
      Map.put(ctx, :owned, pid)
    end

    defp put_owned(ctx, _), do: ctx

    @impl true
    def teardown(ctx) do
      if ctx[:teardown_log] do
        PropertyDamage.log("teardown by #{ctx.name}")
        notify(ctx, {:logged, :teardown, ctx.name})
      end

      if is_pid(ctx[:owned]), do: Agent.stop(ctx.owned)
      if is_pid(ctx[:server]), do: GenServer.stop(ctx.server)
      :ok
    end

    @impl true
    def execute(%F.Act{n: n} = command, ctx, runtime) do
      unless ctx[:quiet] do
        PropertyDamage.log("ran act #{n} by #{ctx.name}")
        notify(ctx, {:logged, :execute, ctx.name})
      end

      ctx |> Map.get(:script, %{}) |> Map.get(n, []) |> Enum.each(&act(&1, n, ctx, runtime))
      F.answer(command, ctx)
    end

    def execute(%F.Probe{} = command, ctx, _runtime) do
      attempt = :atomics.add_get(ctx.attempts, 1, 1)
      PropertyDamage.log("attempt #{attempt}")
      if attempt < 3, do: {:retry, :not_yet}, else: F.answer(command, ctx)
    end

    def execute(%F.Spin{} = command, ctx, _runtime) do
      attempt = :atomics.add_get(ctx.attempts, 1, 1)
      if ctx[:spin_multiline] && attempt == 1, do: PropertyDamage.log("first line\nsecond line")
      PropertyDamage.log("spin attempt #{attempt}")
      if ctx[:spin_detail], do: PropertyDamage.log("spin detail #{attempt}")
      if attempt < Map.get(ctx, :spin_at, 3), do: {:retry, :not_yet}, else: F.answer(command, ctx)
    end

    def execute(%F.Prepare{} = command, ctx, _runtime) do
      PropertyDamage.log("prepare by #{ctx.name}")
      F.answer(command, ctx)
    end

    def execute(%F.Tidy{} = command, ctx, _runtime) do
      PropertyDamage.log("tidy by #{ctx.name}")
      F.answer(command, ctx)
    end

    def execute(%F.Part{root: root, part: part} = command, ctx, _runtime) do
      PropertyDamage.log("part #{root}.#{part} by #{ctx.name}")
      F.answer(command, ctx)
    end

    defp act({:log, message}, _n, _ctx, _runtime), do: PropertyDamage.log(message)

    defp act({:log_http_url, message}, _n, _ctx, _runtime),
      do: PropertyDamage.log(message, tags: [:http, :url])

    defp act({:log_http, message}, _n, _ctx, _runtime),
      do: PropertyDamage.log(message, tags: [:http])

    defp act({:sleep, ms}, _n, _ctx, _runtime), do: Process.sleep(ms)

    defp act({:inject, note}, n, ctx, runtime),
      do: runtime.inject.(%F.Injected{n: n, by: ctx.name, note: note})

    defp act({:nested, message}, _n, _ctx, _runtime) do
      outer =
        Task.async(fn ->
          inner = Task.async(fn -> PropertyDamage.log(message) end)
          Task.await(inner)
        end)

      Task.await(outer)
    end

    defp act({:server, message}, _n, ctx, runtime),
      do: :ok = GenServer.call(ctx.server, {:log, runtime, message})

    defp act(:runtime, _n, ctx, runtime), do: notify(ctx, {:runtime, runtime})

    defp act({:agent_fun, name}, _n, _ctx, _runtime),
      do: PropertyDamage.log(fn -> Agent.get(name, & &1) end)

    defp act(:raising_fun, _n, _ctx, _runtime),
      do: PropertyDamage.log(fn -> raise "a log function raised on purpose" end)

    defp act(:owned_agent_fun, _n, ctx, _runtime) do
      owned = ctx.owned
      PropertyDamage.log(fn -> Agent.get(owned, & &1) end)
    end

    defp act(:no_scope_server, _n, _ctx, _runtime) do
      {:ok, pid} = GenServer.start(F.NoScopeServer, nil)
      GenServer.call(pid, {:log, "from an unscoped server"})
    end

    defp act({:sentinel, parts}, _n, _ctx, _runtime) do
      text = Enum.join(parts, "-")
      PropertyDamage.log(text)
      PropertyDamage.log(%{note: text})
      PropertyDamage.log(fn -> text end)
    end

    defp act({:value, term}, _n, _ctx, _runtime), do: PropertyDamage.log(term)

    # Called through apply/3 so the fixtures compile before capture/1 exists.
    defp act({:capture, message}, _n, ctx, _runtime) do
      {_result, lines} = apply(PropertyDamage.Log, :capture, [fn -> PropertyDamage.log(message) end])
      notify(ctx, {:captured, lines})
    end

    defp notify(%{test_pid: pid}, message) when is_pid(pid), do: send(pid, message)
    defp notify(_config, _message), do: :ok
  end

  defmodule PropertyDamage.Test.LogFixtures.TimeoutLogAdapter do
    @moduledoc false
    # LogAdapter with a 30 ms per-command timeout.
    use PropertyDamage.Adapter

    alias PropertyDamage.Test.LogFixtures.LogAdapter

    @impl true
    def setup(config), do: LogAdapter.setup(config)

    @impl true
    def teardown(ctx), do: LogAdapter.teardown(ctx)

    @impl true
    def timeout(_command), do: {30, :milliseconds}

    @impl true
    def execute(command, ctx, runtime), do: LogAdapter.execute(command, ctx, runtime)
  end

  defmodule PropertyDamage.Test.LogFixtures.ScopelessCheck do
    @moduledoc false
    # A check that logs: a check is not an execution point, so it has no scope.
    use PropertyDamage.Model.Projection
    require PropertyDamage

    @impl true
    def init, do: %{}

    @impl true
    def apply(state, _event), do: state

    @check every: PropertyDamage.Test.LogFixtures.Done
    def assert_logged(_state, _done) do
      PropertyDamage.log("from a check")
      true
    end
  end

  defmodule PropertyDamage.Test.LogFixtures.ScopelessModel do
    @moduledoc false
    @behaviour PropertyDamage.Model

    @impl true
    def commands, do: PropertyDamage.Test.LogFixtures.Model.commands()

    @impl true
    def command_sequence_projection, do: PropertyDamage.Test.LogFixtures.Counter

    @impl true
    def check_projections, do: [PropertyDamage.Test.LogFixtures.ScopelessCheck]
  end

  defmodule PropertyDamage.Test.LogFixtures.Outside do
    @moduledoc false
    # A call with no scope, from whatever process calls `call/0`.
    require PropertyDamage

    def call do
      PropertyDamage.log("outside any scope") # call site: outside
    end
  end
  '''

  @doc false
  def source, do: @source

  @doc false
  def source_file, do: @source_file

  @doc false
  # The line of `@source` that holds `marker`, counted from 1.
  def source_line(marker) do
    index = @source |> String.split("\n") |> Enum.find_index(&String.contains?(&1, marker))
    assert index, "no line holds #{inspect(marker)}"
    index + 1
  end

  @doc false
  # Compiles the modules of `@source` once per VM. Fails the calling test
  # when the source does not compile cleanly: an error, or a warning such as
  # a call to a function that does not exist.
  def compile! do
    key = {__MODULE__, :compiled}

    result =
      case :persistent_term.get(key, nil) do
        nil ->
          :global.trans({{__MODULE__, :compile}, self()}, fn ->
            case :persistent_term.get(key, nil) do
              nil ->
                compiled = compile(@source, @source_file)
                :persistent_term.put(key, compiled)
                compiled

              compiled ->
                compiled
            end
          end)

        compiled ->
          compiled
      end

    case result do
      {:ok, _modules} -> :ok
      {:error, text} -> flunk("the log fixtures did not compile:\n#{text}")
    end
  end

  @doc false
  # Compiles `source` and returns `{:ok, modules}`, or `{:error, text}` with
  # the exception's message and every diagnostic the compiler reported.
  # A warning counts as a failure.
  def compile(source, file) do
    {result, diagnostics} =
      Code.with_diagnostics(fn ->
        try do
          {:ok, source |> Code.compile_string(file) |> Enum.map(&elem(&1, 0))}
        rescue
          exception -> {:error, exception}
        end
      end)

    messages = diagnostics |> Enum.map(&"#{&1.severity}: #{&1.message}") |> Enum.uniq()

    case {result, messages} do
      {{:ok, modules}, []} -> {:ok, modules}
      {{:ok, _modules}, _} -> {:error, Enum.join(messages, "\n")}
      {{:error, e}, _} -> {:error, Enum.join([Exception.message(e) | messages], "\n")}
    end
  end

  @doc false
  # Compiles `source` and returns the exception it raised with the text of
  # every error diagnostic, or `:ok` when it compiled.
  def compile_error(source, file) do
    {result, diagnostics} =
      Code.with_diagnostics(fn ->
        try do
          Code.compile_string(source, file)
          :ok
        rescue
          exception -> {:raised, exception}
        end
      end)

    errors = for %{severity: :error, message: m} <- diagnostics, do: m

    case result do
      :ok -> :ok
      {:raised, e} -> {e, Enum.join([Exception.message(e) | errors], "\n")}
    end
  end

  # ==========================================================================
  # Targets and runs
  # ==========================================================================

  @doc false
  def log_adapter, do: PropertyDamage.Test.LogFixtures.LogAdapter

  @doc false
  def timeout_adapter, do: PropertyDamage.Test.LogFixtures.TimeoutLogAdapter

  @doc false
  # A target of `adapter` named `name`.
  def target(name, config \\ %{}, adapter \\ log_adapter()) do
    {adapter, name: name, config: Map.merge(%{name: name}, config)}
  end

  @doc false
  # One run, unshrunk, with no replay artifact and no validation.
  def run(model, targets, extra \\ []) do
    [
      model: model,
      targets: targets,
      max_runs: 1,
      max_commands: 3,
      seed: 4_242,
      validate: false,
      shrink: false,
      replay_dir: false,
      compare: [converge_within: 50]
    ]
    |> Keyword.merge(extra)
    |> PropertyDamage.run()
  end

  @doc false
  # The failure report a run of `model` returns; fails the test otherwise.
  def report!(model, targets, extra \\ []) do
    case run(model, targets, extra) do
      {:error, %PropertyDamage.FailureReport{} = report} -> report
      other -> flunk("expected a failure report, got: #{inspect(other, limit: 12)}")
    end
  end

  @doc false
  # Calls a function that may not exist yet.
  def call(module, function, args), do: apply(module, function, args)

  @doc false
  # `PropertyDamage.Runtime.log/3`'s module, for `call/3`.
  def runtime_module, do: PropertyDamage.Runtime

  @doc false
  # The lines a trace holds under `key`, by a field the compiler does not see.
  def trace_lines(trace, key), do: trace |> Map.get(:logs, %{}) |> Map.get(key, [])

  @doc false
  # A field that may not exist yet, read by a key the type checker does not
  # see; `default` when the term lacks it.
  def field(term, key, default \\ nil), do: Map.get(term, key, default)

  @doc false
  # The messages of `lines`, in order.
  def messages(lines), do: Enum.map(lines, &Map.get(&1, :message))

  # ==========================================================================
  # Printed reports
  # ==========================================================================

  @doc false
  def plain(report), do: Formatter.format(report, :terminal, color: false)

  @doc false
  def colored(report), do: Formatter.format(report, :terminal, color: true)

  @doc false
  def markdown(report), do: Formatter.format(report, :markdown)

  @doc false
  def strip_ansi(text), do: String.replace(text, ~r/\e\[[0-9;]*m/, "")

  @label ~S"\[(?:setup \d+|teardown \d+|branch \d+\.\d+|\d+(?:\.\d+)?)\]"

  # An event or log line: indent, offset, badge, then the rest.
  @entry ~r/^(\s+)\+(\d+)\.(\d{2})s (\S+)\s+(.*)$/

  @doc false
  # The line form of a log line (DR-054 decision 12): the event column, the
  # offset, the badge `log` padded to five columns, the tags in brackets
  # when there are some, then the message.
  def line_form, do: ~r/^\s+\+\d+\.\d{2}s log   (\[[a-z_ ]+\] )?\S/

  @log ~r/^(\s+)\+(\d+)\.(\d{2})s log   (?:\[([a-z_ ]+)\] )?(.*)$/

  # The line that stands for attempts the retry cap dropped.
  @gap ~r/^(\s+)(\.\.\. (\d[\d,]*) attempts? omitted \((\d[\d,]*) lines?\))$/

  @doc false
  # The body lines of the `## ` section whose heading starts with `name`.
  def section(text, name) do
    lines = String.split(text, "\n")
    start = Enum.find_index(lines, &String.starts_with?(&1, "## " <> name))
    assert start, "no section #{inspect(name)} in:\n#{text}"

    lines
    |> Enum.drop(start + 1)
    |> Enum.take_while(&(not String.starts_with?(&1, "## ")))
  end

  @doc false
  # The listings of the Minimal Reproduction section: `[{header, lines}]`,
  # header nil for a report with one listing.
  def listings(text) do
    body = section(text, "Minimal Reproduction")
    header? = &Regex.match?(~r/^(Reference|Variant): target "/, &1)

    if Enum.any?(body, header?) do
      body
      |> Enum.drop_while(&(not header?.(&1)))
      |> Enum.chunk_while(
        nil,
        fn line, acc ->
          cond do
            header?.(line) and acc == nil -> {:cont, {line, []}}
            header?.(line) -> {:cont, finish(acc), {line, []}}
            true -> {:cont, {elem(acc, 0), [line | elem(acc, 1)]}}
          end
        end,
        fn acc -> {:cont, finish(acc), nil} end
      )
    else
      [{nil, body}]
    end
  end

  defp finish({header, lines}), do: {header, Enum.reverse(lines)}

  @doc false
  # The listing headed `header` (`"Reference"`, `"Variant"`), or the one
  # listing when `header` is nil.
  def listing(text, nil) do
    assert [{nil, lines}] = listings(text)
    lines
  end

  def listing(text, header) do
    found = Enum.find(listings(text), fn {h, _} -> h && String.starts_with?(h, header <> ":") end)
    assert found, "no #{header} listing in:\n#{text}"
    elem(found, 1)
  end

  @doc false
  # A listing's lines as items, in order:
  #
  #   {:step, label, line}
  #   {:note, text}                    a line of two spaces and text
  #   {:entry, entry}                  an event or log line, with the lines
  #                                    that continue it
  #   :blank
  #
  # An entry is `%{kind: :log | :event, line:, indent:, offset:, badge:,
  # tags:, message:, continuation: [line]}`; `offset` in hundredths of a
  # second, `tags` a list of strings (empty for an event).
  def items(lines) do
    lines
    |> Enum.reduce([], fn line, acc ->
      cond do
        String.trim(line) == "" ->
          [:blank | acc]

        match = Regex.run(~r/^(►)?\s*(#{@label})(?:\s|$)/u, line) ->
          [{:step, Enum.at(match, 2), line} | acc]

        Regex.match?(@gap, line) ->
          [{:entry, gap_entry(line)} | acc]

        Regex.match?(@entry, line) ->
          [{:entry, entry(line)} | acc]

        Regex.match?(~r/^  [^\s\[►]/u, line) ->
          [{:note, String.trim(line)} | acc]

        true ->
          continue(acc, line)
      end
    end)
    |> Enum.reverse()
  end

  # A continuation line belongs to the entry above it; under a step line it
  # is the step's own command printed over several lines.
  defp continue([{:entry, entry} | rest], line),
    do: [{:entry, %{entry | continuation: entry.continuation ++ [line]}} | rest]

  defp continue([{:step, label, text} | rest], line),
    do: [{:step, label, text <> "\n" <> line} | rest]

  defp continue(acc, line),
    do: flunk("a line continues nothing: #{inspect(line)}\n#{inspect(acc)}")

  # A gap is an entry of kind `:gap`: its text is the message, its counts
  # are parsed (thousands separators removed), and it has no offset.
  defp gap_entry(line) do
    [_, indent, text, attempts, lines] = Regex.run(@gap, line)

    %{
      kind: :gap,
      line: line,
      indent: String.length(indent),
      offset: nil,
      badge: nil,
      tags: [],
      message: text,
      attempts: attempts |> String.replace(",", "") |> String.to_integer(),
      lines: lines |> String.replace(",", "") |> String.to_integer(),
      continuation: []
    }
  end

  defp entry(line) do
    case Regex.run(@log, line) do
      [_, indent, s, cs, tags, message] ->
        %{
          kind: :log,
          line: line,
          indent: String.length(indent),
          offset: String.to_integer(s) * 100 + String.to_integer(cs),
          badge: "log",
          tags: String.split(tags, " ", trim: true),
          message: message,
          continuation: []
        }

      nil ->
        [_, indent, s, cs, badge, rest] = Regex.run(@entry, line)

        %{
          kind: :event,
          line: line,
          indent: String.length(indent),
          offset: String.to_integer(s) * 100 + String.to_integer(cs),
          badge: badge,
          tags: [],
          message: rest,
          continuation: []
        }
    end
  end

  @doc false
  # The entries under the step labeled `label`: from its line to the next
  # step, note, blank or header line. Fails when the label is not listed
  # exactly once.
  def block(lines, label) do
    items = items(lines)
    at = for {{:step, ^label, _}, i} <- Enum.with_index(items), do: i

    assert length(at) == 1,
           "step #{label} listed #{length(at)} times in:\n#{Enum.join(lines, "\n")}"

    [i] = at

    items
    |> Enum.drop(i + 1)
    |> Enum.take_while(&match?({:entry, _}, &1))
    |> Enum.map(&elem(&1, 1))
  end

  @doc false
  # The step labels of a listing, in order.
  def labels(lines), do: for({:step, label, _} <- items(lines), do: label)

  @doc false
  # `[{label, entries}]` for every step of a listing.
  def blocks(lines), do: Enum.map(labels(lines), &{&1, block(lines, &1)})

  @doc false
  # The entries under the note line `note`, up to the next step, note or
  # blank line; nil when the note is not printed.
  def note_block(lines, note) do
    items = items(lines)

    case Enum.find_index(items, &(&1 == {:note, note})) do
      nil ->
        nil

      i ->
        items
        |> Enum.drop(i + 1)
        |> Enum.take_while(&match?({:entry, _}, &1))
        |> Enum.map(&elem(&1, 1))
    end
  end

  @doc false
  # The index of the first item of a listing for which `fun` holds.
  def item_index(lines, fun), do: lines |> items() |> Enum.find_index(fun)

  @doc false
  def logs(entries), do: Enum.filter(entries, &(&1.kind == :log))

  @doc false
  def gaps(entries), do: Enum.filter(entries, &(&1.kind == :gap))

  @doc false
  # What a step shows of its log lines, in order: each line's message, each
  # gap as `{:gap, text}`. Events are left out.
  def shown_logs(entries) do
    for %{kind: kind} = entry <- entries, kind in [:log, :gap] do
      if kind == :log, do: entry.message, else: {:gap, entry.message}
    end
  end

  @doc false
  def events(entries), do: Enum.filter(entries, &(&1.kind == :event))

  @doc false
  # Every log entry of a listing, under a step or a note.
  def all_logs(lines), do: for({:entry, %{kind: :log} = e} <- items(lines), do: e)

  @doc false
  # The full text of an entry, its continuation lines joined with newlines.
  def entry_text(entry), do: Enum.join([entry.line | entry.continuation], "\n")

  # ==========================================================================
  # Checks
  # ==========================================================================

  @doc false
  # Every log line of `lines` has the line form, at the column of the event
  # lines, and continues at its message column.
  def assert_line_form(lines) do
    entries = for {:entry, e} <- items(lines), do: e
    log_entries = logs(entries)
    assert log_entries != [], "no log line in:\n#{Enum.join(lines, "\n")}"

    for e <- log_entries do
      assert Regex.match?(line_form(), e.line), "not a log line form: #{inspect(e.line)}"
      column = message_column(e)

      for line <- e.continuation do
        assert String.starts_with?(line, String.duplicate(" ", column)),
               "continuation not at the message column #{column}: #{inspect(line)}"
      end
    end

    columns = entries |> Enum.map(& &1.indent) |> Enum.uniq()
    assert length(columns) == 1, "log and event lines start at columns #{inspect(columns)}"
    :ok
  end

  @doc false
  # The column a log line's message starts at.
  def message_column(entry), do: String.length(entry.line) - String.length(entry.message)

  @doc false
  # Offsets that never decrease, none negative (a negative offset would not
  # parse as `+S.SSs`).
  def assert_offsets_ordered(entries) do
    offsets = for %{offset: offset} when offset != nil <- entries, do: offset
    assert offsets == Enum.sort(offsets), "offsets out of order: #{inspect(offsets)}"
    :ok
  end

  @doc false
  # Under the step `label`, the log lines are exactly `expected`, in order:
  # `[{message, tags}]`, tags as printed. Each has the line form.
  def assert_logs(lines, label, expected) do
    found = lines |> block(label) |> logs()
    pairs = Enum.map(found, &{&1.message, &1.tags})
    assert pairs == expected, "under #{label}: #{inspect(pairs)}, expected #{inspect(expected)}"
    for e <- found, do: assert(Regex.match?(line_form(), e.line), "line form: #{inspect(e.line)}")
    :ok
  end

  @doc false
  # Under the step `label`, the entries in order match `expected`: each
  # `{:log, message}` a log line with that message, each `{:event, fragment}`
  # an event line holding the fragment. Offsets never decrease.
  def assert_entries(lines, label, expected) do
    entries = block(lines, label)
    shown = Enum.map(entries, &{&1.kind, &1.message})

    assert length(entries) == length(expected),
           "under #{label}: #{inspect(shown)}, expected #{inspect(expected)}"

    for {entry, want} <- Enum.zip(entries, expected) do
      case want do
        {:log, message} ->
          assert {entry.kind, entry.message} == {:log, message},
                 "under #{label}: #{inspect(shown)}, expected #{inspect(expected)}"

        {:event, fragment} ->
          assert entry.kind == :event and String.contains?(entry_text(entry), fragment),
                 "under #{label}: #{inspect(shown)}, expected #{inspect(expected)}"
      end
    end

    assert_offsets_ordered(entries)
  end

  @doc false
  # The first log line of a listing prints at +0.00s.
  def assert_first_log_at_zero(lines) do
    assert [first | _] = all_logs(lines)
    assert first.offset == 0, "the first line prints at #{first.offset / 100}s: #{first.line}"
    :ok
  end

  @doc false
  # Every block's offsets never decrease.
  def assert_all_offsets_ordered(lines) do
    for {_label, entries} <- blocks(lines), do: assert_offsets_ordered(entries)
    :ok
  end

  @doc false
  # The one log line whose message is `message` has no tags and no brackets.
  def assert_untagged(lines, message) do
    assert [e] = Enum.filter(all_logs(lines), &(&1.message == message))
    assert e.tags == [] and not String.contains?(e.line, "log   ["), "tagged: #{inspect(e.line)}"
    :ok
  end

  @doc false
  # A string message printed over two lines: `first` on the line, `second`
  # alone on the next line, at the message column.
  def assert_string_continues(lines, first, second) do
    assert [e] = Enum.filter(all_logs(lines), &(&1.message == first))
    assert e.continuation == [String.duplicate(" ", message_column(e)) <> second]
    :ok
  end

  @doc false
  # The log line whose text holds `fragment` prints over several lines, each
  # continuation at least at the message column.
  def assert_value_continues(lines, fragment) do
    assert [e] = Enum.filter(all_logs(lines), &String.contains?(entry_text(&1), fragment))
    assert e.continuation != [], "one line only: #{inspect(e.line)}"
    pad = String.duplicate(" ", message_column(e))
    for line <- e.continuation, do: assert(String.starts_with?(line, pad), inspect(line))
    :ok
  end

  @doc false
  # The note line `note` prints before the first step, and the log line
  # `message` sits under it.
  def assert_note_lines(lines, note, message, before_steps? \\ true) do
    entries = note_block(lines, note)
    assert entries, "no note #{inspect(note)} in:\n#{Enum.join(lines, "\n")}"
    assert Enum.any?(logs(entries), &(&1.message == message)), "#{message} not under #{note}"

    if before_steps? do
      note_at = item_index(lines, &(&1 == {:note, note}))
      step_at = item_index(lines, &match?({:step, _, _}, &1))
      assert step_at == nil or note_at < step_at, "#{note} after the first step"
    end

    :ok
  end

  @doc false
  # The one fenced block of the markdown section `name`.
  def fenced_body(markdown, name) do
    lines = section(markdown, name)
    open = Enum.find_index(lines, &String.starts_with?(&1, "```"))
    assert open, "no fence in #{name}"
    rest = Enum.drop(lines, open + 1)
    close = Enum.find_index(rest, &String.starts_with?(&1, "```"))
    assert close, "no closing fence in #{name}"
    Enum.take(rest, close)
  end

  @doc false
  # The plain lines of a section without the blank lines at either end.
  def trimmed(lines) do
    lines
    |> Enum.drop_while(&(String.trim(&1) == ""))
    |> Enum.reverse()
    |> Enum.drop_while(&(String.trim(&1) == ""))
    |> Enum.reverse()
  end

  @doc false
  # The markdown's Minimal Reproduction fenced body equals the plain
  # terminal body.
  def assert_markdown_mirrors(markdown, plain) do
    name = "Minimal Reproduction"
    assert fenced_body(markdown, name) == trimmed(section(plain, name))
    :ok
  end

  # ==========================================================================
  # Terms
  # ==========================================================================

  @doc false
  # The text the `{:sentinel, parts}` action logs, and its parts.
  def sentinel, do: Enum.join(sentinel_parts(), "-")

  @doc false
  def sentinel_parts, do: ["SENTINEL-LOG", "LINE-7f3a"]

  @doc false
  def no_scope_error, do: Module.concat([PropertyDamage, Log, NoScopeError])

  @doc false
  def line_module, do: Module.concat([PropertyDamage, Log, Line])

  @doc false
  def gap_module, do: Module.concat([PropertyDamage, Log, Gap])

  @doc false
  # A log line as `PropertyDamage.Log.capture/1` returns it. `at` is its
  # timestamp, in milliseconds.
  def line(message, opts \\ []) do
    %PropertyDamage.Log.Line{
      message: message,
      tags: Keyword.get(opts, :tags, []),
      file: "setup.exs",
      line: 1,
      timestamp: Keyword.get(opts, :at, System.monotonic_time(:millisecond)),
      attempt: 1
    }
  end

  @doc false
  # Setup lines far earlier than any run's events, so one that entered a
  # target's offset origin would show as a large offset there. Given out of
  # timestamp order on purpose.
  def setup_lines do
    base = System.monotonic_time(:millisecond) - 3_600_000

    [
      line("seeded 3 accounts", tags: [:seed], at: base + 1_250),
      line("opening the ledger", at: base),
      line(%{alice: 100, bob: 0}, tags: [:seed, :rows], at: base + 30)
    ]
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
