defmodule PropertyDamage.Test.Lockstep do
  @moduledoc false
  # Models, commands, events and adapters shared by the variant, scheduler and
  # multi-target run tests. Each adapter reads its behavior from its target's
  # `config:` map, so one module can play a reference and a candidate.
  #
  # Messages adapters send to `config.test_pid` (when set):
  #
  #   {:setup, name, pid}            setup/1 ran in process `pid`
  #   {:setup_done, name, pid}       a delayed setup/1 is about to return
  #   {:setup_waiting, name, pid}    setup/1 blocks until `pid` receives :release_setup
  #   {:drawn, name, value}          the first `:rand.uniform/1` draw in setup/1
  #   {:teardown, name, pid}         teardown/1 ran in process `pid`
  #   {:executed, name, index, callers}
  #                                  execute/3 ran its `index`-th call of this run;
  #                                  `callers` is `self()` plus the `$callers` chain

  alias PropertyDamage.Generator
  alias PropertyDamage.Test.VariantSupport

  @doc false
  def notify(%{test_pid: pid}, message) when is_pid(pid), do: send(pid, message)
  def notify(_config, _message), do: :ok

  @doc false
  # The process that owns this call: `self()` followed by the processes that
  # started it (a per-command Task records its parent in `$callers`).
  def callers, do: [self() | Process.get(:"$callers", [])]

  # ==========================================================================
  # Events
  # ==========================================================================

  defmodule Stepped do
    @moduledoc false
    defstruct [:value, :id, :mark]
  end

  defmodule Noted do
    @moduledoc false
    defstruct [:value]
  end

  defmodule Polled do
    @moduledoc false
    defstruct [:id]
  end

  defmodule Late do
    @moduledoc false
    defstruct [:from]
  end

  defmodule Delivered do
    @moduledoc false
    defstruct []
  end

  defmodule Started do
    @moduledoc false
    defstruct [:id]
  end

  defmodule Ignored do
    @moduledoc false
    defstruct [:id]
  end

  defmodule Confirmed do
    @moduledoc false
    defstruct [:id]
  end

  defmodule Probed do
    @moduledoc false
    defstruct [:value]
  end

  defmodule FaultInjected do
    @moduledoc false
    defstruct [:tag]
  end

  defmodule FaultRestored do
    @moduledoc false
    defstruct [:tag]
  end

  defmodule CloseRequested do
    @moduledoc false
    defstruct [:issue_id]
  end

  defmodule ClosedWebhook do
    @moduledoc false
    defstruct [:issue_id]
  end

  defmodule Created do
    @moduledoc false
    import PropertyDamage, only: [external: 0]
    defstruct [:label, id: external()]
  end

  defmodule Used do
    @moduledoc false
    defstruct [:target]
  end

  # ==========================================================================
  # Commands
  # ==========================================================================

  defmodule Step do
    @moduledoc false
    use PropertyDamage.Command
    defstruct [:value, fail: false]

    @impl true
    def generator(overrides \\ %{}) do
      %{value: StreamData.integer(1..100), fail: StreamData.constant(false)}
      |> Generator.merge_overrides(overrides)
      |> StreamData.fixed_map()
    end
  end

  defmodule ProbeStep do
    @moduledoc false
    use PropertyDamage.Command,
      execution: :probe,
      settle: %{timeout_ms: 2_000, interval_ms: 5, backoff: :linear}

    defstruct [:value]

    @impl true
    def generator(overrides \\ %{}) do
      %{value: StreamData.integer(1..100)}
      |> Generator.merge_overrides(overrides)
      |> StreamData.fixed_map()
    end
  end

  defmodule Deliver do
    @moduledoc false
    use PropertyDamage.Command
    defstruct [:coordinator]

    @impl true
    def generator(_overrides \\ %{}), do: StreamData.constant(%{coordinator: nil})
  end

  defmodule Begin do
    @moduledoc false
    use PropertyDamage.Command
    defstruct [:id]

    @impl true
    def generator(_overrides \\ %{}), do: StreamData.constant(%{id: "p1"})
  end

  defmodule Nudge do
    @moduledoc false
    use PropertyDamage.Command
    defstruct []

    @impl true
    def generator(_overrides \\ %{}), do: StreamData.constant(%{})
  end

  defmodule CloseIssue do
    @moduledoc false
    use PropertyDamage.Command
    defstruct [:issue_id]

    @impl true
    def generator(_overrides \\ %{}), do: StreamData.constant(%{issue_id: "i1"})

    # The closing webhook for this issue belongs to this command.
    @impl true
    def awaits(_state, %__MODULE__{issue_id: id}) do
      [
        %PropertyDamage.Await{
          match: fn
            %ClosedWebhook{issue_id: ^id} -> true
            _ -> false
          end
        }
      ]
    end
  end

  defmodule Create do
    @moduledoc false
    @behaviour PropertyDamage.Command
    defstruct [:label]

    @impl true
    def generator(overrides) do
      StreamData.fixed_map(
        Generator.merge_overrides(%{label: StreamData.constant("x")}, overrides)
      )
    end
  end

  defmodule Use do
    @moduledoc false
    @behaviour PropertyDamage.Command
    defstruct [:target]

    @impl true
    def generator(overrides) do
      StreamData.fixed_map(
        Generator.merge_overrides(%{target: StreamData.constant(nil)}, overrides)
      )
    end
  end

  # A fault whose injection and restoration are reported to the adapter
  # context's `test_pid`, as `{:fault_injected, tag, pid}` and
  # `{:fault_restored, tag, pid}`.
  defmodule TimedFault do
    @moduledoc false
    @behaviour PropertyDamage.Nemesis

    alias PropertyDamage.Test.Lockstep

    defstruct duration_ms: 0, tag: :fault

    @impl true
    def precondition(_state), do: true

    @impl true
    def inject(%__MODULE__{tag: tag}, context) do
      Lockstep.notify(context.adapter_context, {:fault_injected, tag, self()})
      {:ok, [%FaultInjected{tag: tag}]}
    end

    @impl true
    def restore(%__MODULE__{tag: tag}, context) do
      Lockstep.notify(context.adapter_context, {:fault_restored, tag, self()})
      {:ok, [%FaultRestored{tag: tag}]}
    end

    @impl true
    def auto_restore?, do: true

    @impl true
    def duration_ms(%__MODULE__{duration_ms: duration}), do: duration
  end

  # ==========================================================================
  # Projections
  # ==========================================================================

  defmodule Ledger do
    @moduledoc false
    # Records what each variant folded, by kind.
    @behaviour PropertyDamage.Model.Projection

    @impl true
    def init do
      %{commands: 0, stepped: [], noted: [], polled: [], late: [], probed: [], faults: []}
    end

    @impl true
    def apply(state, %Step{}), do: %{state | commands: state.commands + 1}
    def apply(state, %ProbeStep{}), do: %{state | commands: state.commands + 1}
    def apply(state, %Deliver{}), do: %{state | commands: state.commands + 1}
    def apply(state, %Stepped{value: v}), do: %{state | stepped: [v | state.stepped]}
    def apply(state, %Noted{value: v}), do: %{state | noted: [v | state.noted]}
    def apply(state, %Polled{id: id}), do: %{state | polled: [id | state.polled]}
    def apply(state, %Late{from: from}), do: %{state | late: [from | state.late]}
    def apply(state, %Probed{value: v}), do: %{state | probed: [v | state.probed]}
    def apply(state, %FaultInjected{tag: t}), do: %{state | faults: [{:on, t} | state.faults]}
    def apply(state, %FaultRestored{tag: t}), do: %{state | faults: [{:off, t} | state.faults]}
    def apply(state, _other), do: state
  end

  defmodule StepGuard do
    @moduledoc false
    # Fails on a Stepped event whose value is 13 or that is marked bad.
    use PropertyDamage.Model.Projection

    @impl true
    def init, do: %{}

    @impl true
    def apply(state, _), do: state

    @check every: Stepped
    def assert_step_is_good(_state, %Stepped{value: value, mark: mark}) do
      if value == 13 or mark == :bad do
        PropertyDamage.fail!("bad step", value: value, mark: mark)
      end

      :ok
    end
  end

  defmodule StartupGuard do
    @moduledoc false
    # Fails at startup when the process running the checks was marked by an
    # adapter's setup/1 (`fail_startup: true` in its config). The check reads
    # the process dictionary, so it fails only in the process that ran that
    # setup/1.
    use PropertyDamage.Model.Projection

    @impl true
    def init, do: %{}

    @impl true
    def apply(state, _), do: state

    @check at: :startup
    def assert_ready(_state, _phase) do
      if Process.get(:lockstep_fail_startup) do
        PropertyDamage.fail!("startup precondition not met")
      end

      :ok
    end
  end

  defmodule DrainRelease do
    @moduledoc false
    # After each Deliver command, and after the step has drained the event
    # queue, release the resource poller that command started and wait until
    # it exits. The poller pushes its event before it exits, so when the step
    # returns that event is waiting in the queue.
    use PropertyDamage.Model.Projection

    @impl true
    def init, do: %{}

    @impl true
    def apply(state, _), do: state

    @check every: Deliver
    def assert_released(_state, %Deliver{coordinator: coordinator}) do
      poller = Agent.get(coordinator, & &1)
      ref = Process.monitor(poller)
      send(poller, :go)

      receive do
        {:DOWN, ^ref, :process, _, _} -> :ok
      after
        2_000 -> :ok
      end

      :ok
    end
  end

  defmodule OwnershipProjection do
    @moduledoc false
    use PropertyDamage.Model.Projection

    @impl true
    def init, do: %{confirmed: %{}, started: [], ignored: []}

    @impl true
    def apply(state, %Started{id: id}), do: %{state | started: [id | state.started]}
    def apply(state, %Ignored{id: id}), do: %{state | ignored: [id | state.ignored]}
    def apply(state, %Confirmed{id: id}), do: put_in(state.confirmed[id], true)
    def apply(state, _), do: state

    @eventually after: Started, timeout: {5_000, :milliseconds}, interval: {10, :milliseconds}
    def started_is_confirmed(_state, %Started{id: id}) do
      fn s -> Map.get(s.confirmed, id, false) end
    end
  end

  defmodule PolledProjection do
    @moduledoc false
    # Every Stepped value is eventually reported back by a resource poller.
    use PropertyDamage.Model.Projection

    @impl true
    def init, do: %{polled: []}

    @impl true
    def apply(state, %Polled{id: id}), do: %{state | polled: [id | state.polled]}
    def apply(state, _), do: state

    @eventually after: Stepped, timeout: {500, :milliseconds}, interval: {10, :milliseconds}
    def stepped_is_polled(_state, %Stepped{value: value}) do
      fn s -> value in s.polled end
    end
  end

  defmodule IssueProjection do
    @moduledoc false
    use PropertyDamage.Model.Projection

    @impl true
    def init, do: %{closed: %{}, webhooks: %{}}

    @impl true
    def apply(state, %CloseRequested{issue_id: id}), do: put_in(state.closed[id], true)

    def apply(state, %ClosedWebhook{issue_id: id}),
      do: update_in(state, [:webhooks, id], fn n -> (n || 0) + 1 end)

    def apply(state, _), do: state

    @eventually after: CloseRequested,
                timeout: {1_000, :milliseconds},
                interval: {10, :milliseconds}
    def webhook_arrives(_state, %CloseRequested{issue_id: id}) do
      fn s -> (s.webhooks[id] || 0) >= 1 end
    end
  end

  defmodule RoutingProjection do
    @moduledoc false
    @behaviour PropertyDamage.Model.Projection

    @impl true
    def init, do: %{created: [], used: []}

    @impl true
    def apply(state, %Created{id: id}), do: %{state | created: [id | state.created]}
    def apply(state, %Used{target: target}), do: %{state | used: [target | state.used]}
    def apply(state, _other), do: state
  end

  # ==========================================================================
  # Models (no model lists one projection both as the sequence projection and
  # as a check projection)
  # ==========================================================================

  defmodule StepModel do
    @moduledoc false
    @behaviour PropertyDamage.Model

    @impl true
    def commands, do: [Step]

    @impl true
    def command_sequence_projection, do: Ledger
  end

  defmodule GuardedStepModel do
    @moduledoc false
    @behaviour PropertyDamage.Model

    @impl true
    def commands, do: [Step]

    @impl true
    def command_sequence_projection, do: Ledger

    @impl true
    def check_projections, do: [StepGuard]
  end

  defmodule StartupModel do
    @moduledoc false
    @behaviour PropertyDamage.Model

    @impl true
    def commands, do: [Step]

    @impl true
    def command_sequence_projection, do: Ledger

    @impl true
    def check_projections, do: [StartupGuard]
  end

  defmodule PolledModel do
    @moduledoc false
    @behaviour PropertyDamage.Model

    @impl true
    def commands, do: [Step]

    @impl true
    def command_sequence_projection, do: Ledger

    @impl true
    def check_projections, do: [PolledProjection]
  end

  defmodule ProbeModel do
    @moduledoc false
    @behaviour PropertyDamage.Model

    @impl true
    def commands, do: [ProbeStep]

    @impl true
    def command_sequence_projection, do: Ledger
  end

  defmodule DrainModel do
    @moduledoc false
    @behaviour PropertyDamage.Model

    @impl true
    def commands, do: [Deliver]

    @impl true
    def command_sequence_projection, do: Ledger

    @impl true
    def check_projections, do: [DrainRelease]
  end

  defmodule OwnershipModel do
    @moduledoc false
    @behaviour PropertyDamage.Model

    @impl true
    def commands, do: [Begin, Nudge]

    @impl true
    def command_sequence_projection, do: OwnershipProjection
  end

  defmodule IssueModel do
    @moduledoc false
    @behaviour PropertyDamage.Model

    @impl true
    def commands, do: [CloseIssue]

    @impl true
    def command_sequence_projection, do: IssueProjection
  end

  defmodule RoutingModel do
    @moduledoc false
    @behaviour PropertyDamage.Model
    @behaviour PropertyDamage.Model.Simulator

    @impl true
    def commands do
      [
        Create,
        {Use,
         when: fn state -> state.created != [] end,
         overrides: fn state -> %{target: Generator.external_from(state, path: [:id])} end}
      ]
    end

    @impl true
    def command_sequence_projection, do: RoutingProjection

    @impl true
    def simulator, do: __MODULE__

    @impl PropertyDamage.Model.Simulator
    def simulate(%Create{label: label}, _state), do: [%Created{label: label}]
    def simulate(%Use{target: target}, _state), do: [%Used{target: target}]
    def simulate(_command, _state), do: []
  end

  # ==========================================================================
  # Adapters
  # ==========================================================================

  defmodule StepAdapter do
    @moduledoc false
    # Config keys (all optional):
    #
    #   :name          label used in messages (default "step")
    #   :test_pid      receives the messages listed in the module doc above
    #   :recorder      VariantSupport recorder; gets {:enter, name, index} and
    #                  {:exit, name, index} around every call, and
    #                  {:setup, name} / {:teardown, name}
    #   :counter       Agent holding %{name => setups so far}; the run index of
    #                  this setup is stored as `:run` in the context
    #   :behavior      :echo (default) | :shift | :inject | :inject_shift |
    #                  :new_id | :raise | :error
    #   :raise_on_run  raise from execute/3 in that run (0-based) only
    #   :bad_at        mark the Stepped event of that call index as :bad
    #   :poll          :deliver or :never: each call starts a resource poller
    #                  that reports the command's value as Polled (or never)
    #   :barrier       VariantSupport.Barrier: each call arrives with its index
    #   :hold_ms       sleep between {:enter, ...} and {:exit, ...}
    #   :draw          report the first :rand.uniform/1 draw of setup/1
    #   :setup_delay_ms, :hold_setup, :setup_result (:error | :raise),
    #   :fail_startup  mark this process so StartupGuard fails
    use PropertyDamage.Adapter

    alias PropertyDamage.Test.Lockstep
    alias PropertyDamage.Test.Lockstep.{Noted, Polled, Step, Stepped}
    alias PropertyDamage.Test.VariantSupport
    alias PropertyDamage.Test.VariantSupport.Barrier

    @impl true
    def setup(config) do
      name = Map.get(config, :name, "step")

      if config[:draw] do
        Lockstep.notify(config, {:drawn, name, :rand.uniform(1_000_000_000)})
      end

      if config[:fail_startup], do: Process.put(:lockstep_fail_startup, true)

      Lockstep.notify(config, {:setup, name, self()})
      VariantSupport.record(config[:recorder], {:setup, name})

      if delay = config[:setup_delay_ms] do
        Process.sleep(delay)
        Lockstep.notify(config, {:setup_done, name, self()})
        VariantSupport.record(config[:recorder], {:setup_done, name})
      end

      if config[:hold_setup] do
        Lockstep.notify(config, {:setup_waiting, name, self()})

        receive do
          :release_setup -> :ok
        after
          10_000 -> :ok
        end
      end

      run = next_run(config, name)

      case config[:setup_result] do
        :error ->
          {:error, :no_backend}

        :raise ->
          raise "setup exploded"

        _ ->
          {:ok, Map.merge(config, %{name: name, run: run, calls: :atomics.new(1, [])})}
      end
    end

    @impl true
    def teardown(ctx) do
      Lockstep.notify(ctx, {:teardown, ctx.name, self()})
      VariantSupport.record(ctx[:recorder], {:teardown, ctx.name})
      :ok
    end

    @impl true
    def execute(%Step{value: value} = command, ctx, runtime) do
      index = :atomics.add_get(ctx.calls, 1, 1) - 1
      VariantSupport.record(ctx[:recorder], {:enter, ctx.name, index})

      if barrier = ctx[:barrier] do
        VariantSupport.record(
          ctx[:recorder],
          {:barrier, ctx.name, index, Barrier.arrive(barrier, index, 2_000)}
        )
      end

      if hold = ctx[:hold_ms], do: Process.sleep(hold)

      maybe_poll(ctx[:poll], value, runtime)

      VariantSupport.record(ctx[:recorder], {:exit, ctx.name, index})
      Lockstep.notify(ctx, {:executed, ctx.name, index, Lockstep.callers()})

      respond(command, index, ctx, runtime)
    end

    defp respond(%Step{fail: true}, _index, _ctx, _runtime), do: {:error, :refused}

    defp respond(%Step{value: value}, index, ctx, runtime) do
      cond do
        ctx[:raise_on_run] == ctx.run -> raise "candidate exploded"
        ctx[:bad_at] == index -> {:ok, [%Stepped{value: value, mark: :bad}]}
        true -> behave(Map.get(ctx, :behavior, :echo), value, ctx, runtime)
      end
    end

    defp behave(:echo, value, _ctx, _runtime), do: {:ok, [%Stepped{value: value}]}
    defp behave(:shift, value, _ctx, _runtime), do: {:ok, [%Stepped{value: value + 1}]}
    defp behave(:new_id, value, ctx, _runtime), do: {:ok, [%Stepped{value: value, id: ctx.name}]}
    defp behave(:raise, _value, _ctx, _runtime), do: raise("candidate exploded")
    defp behave(:error, _value, _ctx, _runtime), do: {:error, :refused}

    defp behave(:inject, value, _ctx, runtime) do
      runtime.inject.(%Noted{value: value})
      {:ok, [%Stepped{value: value}]}
    end

    defp behave(:inject_shift, value, _ctx, runtime) do
      runtime.inject.(%Noted{value: value})
      {:ok, [%Stepped{value: value + 1}]}
    end

    defp maybe_poll(nil, _value, _runtime), do: :ok

    defp maybe_poll(mode, value, runtime) do
      runtime.start_poller.(
        poll_fn: fn -> mode end,
        handler: fn
          :deliver -> {:done, [%Polled{id: value}]}
          :never -> :continue
        end,
        interval_ms: 10,
        timeout_ms: 400,
        on_timeout: :ignore
      )

      :ok
    end

    defp next_run(config, name) do
      case config[:counter] do
        nil ->
          0

        counter ->
          Agent.get_and_update(counter, fn counts ->
            n = Map.get(counts, name, 0)
            {n, Map.put(counts, name, n + 1)}
          end)
      end
    end
  end

  defmodule ProbeAdapter do
    @moduledoc false
    # Answers {:retry, _} `retries` times per command, then the settled event.
    # `offset` is added to the settled value (0 for a faithful target).
    use PropertyDamage.Adapter

    alias PropertyDamage.Test.Lockstep.{Probed, ProbeStep}

    @impl true
    def setup(config), do: {:ok, Map.put(config, :attempts, :atomics.new(1, []))}

    @impl true
    def teardown(_ctx), do: :ok

    @impl true
    def execute(%ProbeStep{value: value}, ctx, _runtime) do
      attempt = :atomics.add_get(ctx.attempts, 1, 1)
      retries = Map.get(ctx, :retries, 2)

      if rem(attempt, retries + 1) == 0 do
        {:ok, [%Probed{value: value + Map.get(ctx, :offset, 0)}]}
      else
        {:retry, {:not_ready, rem(attempt, retries + 1)}}
      end
    end
  end

  defmodule DrainAdapter do
    @moduledoc false
    # Each Deliver starts a resource poller that blocks until it receives :go,
    # then pushes one Late event and exits. The poller pid is left in the
    # command's coordinator agent for DrainRelease.
    use PropertyDamage.Adapter

    alias PropertyDamage.Test.Lockstep.{Deliver, Delivered, Late}

    @impl true
    def setup(config), do: {:ok, config}

    @impl true
    def teardown(_ctx), do: :ok

    @impl true
    def execute(%Deliver{coordinator: coordinator}, _ctx, runtime) do
      poller =
        runtime.start_poller.(
          poll_fn: fn ->
            receive do
              :go -> :ready
            after
              5_000 -> :never
            end
          end,
          handler: fn
            :ready -> {:done, [%Late{from: :poller}]}
            :never -> {:done, []}
          end,
          interval_ms: 10,
          timeout_ms: 10_000
        )

      Agent.update(coordinator, fn _ -> poller.pid end)
      {:ok, [%Delivered{}]}
    end
  end

  defmodule OwnershipAdapter do
    @moduledoc false
    # With `poll: true` a Begin returns Started (the @eventually trigger) and
    # starts a resource poller that confirms once the gate agent holds true;
    # with `poll: false` it returns Ignored and starts nothing.
    use PropertyDamage.Adapter

    alias PropertyDamage.Test.Lockstep.{Begin, Confirmed, Ignored, Nudge, Started}

    @impl true
    def setup(config), do: {:ok, config}

    @impl true
    def teardown(_ctx), do: :ok

    @impl true
    def execute(%Begin{id: id}, %{poll: true} = ctx, runtime) do
      gate = ctx.gate

      runtime.start_poller.(
        poll_fn: fn -> Agent.get(gate, & &1) end,
        handler: fn
          true -> {:done, [%Confirmed{id: id}]}
          false -> :continue
        end,
        interval_ms: 10,
        timeout_ms: 10_000
      )

      {:ok, [%Started{id: id}]}
    end

    def execute(%Begin{id: id}, _ctx, _runtime), do: {:ok, [%Ignored{id: id}]}
    def execute(%Nudge{}, _ctx, _runtime), do: {:ok, []}
  end

  defmodule MintingAdapter do
    @moduledoc false
    # Mints `<prefix>_id_<n>` for each Create and echoes each Use's resolved
    # target; every command it receives is sent to `test_pid` as
    # {:received, prefix, command}.
    use PropertyDamage.Adapter

    alias PropertyDamage.Test.Lockstep
    alias PropertyDamage.Test.Lockstep.{Create, Created, Use, Used}

    @impl true
    def setup(config), do: {:ok, Map.put(config, :minted, :atomics.new(1, []))}

    @impl true
    def teardown(_ctx), do: :ok

    @impl true
    def execute(%Create{label: label} = command, ctx, _runtime) do
      Lockstep.notify(ctx, {:received, ctx.prefix, command})
      n = :atomics.add_get(ctx.minted, 1, 1)
      {:ok, [%Created{label: label, id: "#{ctx.prefix}_id_#{n}"}]}
    end

    def execute(%Use{target: target} = command, ctx, _runtime) do
      Lockstep.notify(ctx, {:received, ctx.prefix, command})
      {:ok, [%Used{target: target}]}
    end
  end

  defmodule IssueAdapter do
    @moduledoc false
    use PropertyDamage.Adapter

    alias PropertyDamage.Test.Lockstep.{CloseIssue, CloseRequested}

    @impl true
    def setup(config), do: {:ok, config}

    @impl true
    def teardown(_ctx), do: :ok

    @impl true
    def execute(%CloseIssue{issue_id: id}, _ctx, _runtime),
      do: {:ok, [%CloseRequested{issue_id: id}]}
  end

  defmodule WebhookInjector do
    @moduledoc false
    # Delivers the closing webhook for issue "i1" as soon as it is set up.
    use PropertyDamage.Adapter.Injector

    alias PropertyDamage.EventQueue
    alias PropertyDamage.Test.Lockstep.ClosedWebhook

    @emits [ClosedWebhook]

    @impl true
    def setup(%{event_queue: queue} = config) do
      EventQueue.push(queue, __MODULE__, %ClosedWebhook{issue_id: "i1"})
      {:ok, config}
    end

    @impl true
    def teardown(_context), do: :ok

    @impl true
    def to_event(payload), do: {:ok, payload}
  end

  defmodule NoteInjector do
    @moduledoc false
    # Delivers one Noted event as soon as it is set up.
    use PropertyDamage.Adapter.Injector

    alias PropertyDamage.EventQueue
    alias PropertyDamage.Test.Lockstep.Noted

    @emits [Noted]

    @impl true
    def setup(%{event_queue: queue} = config) do
      EventQueue.push(queue, __MODULE__, %Noted{value: :from_injector})
      {:ok, config}
    end

    @impl true
    def teardown(_context), do: :ok

    @impl true
    def to_event(payload), do: {:ok, payload}
  end

  defmodule CountingMock do
    @moduledoc false
    # A mock service that reports its setup to `test_pid` as
    # {:mock_setup, name, pid}.
    use PropertyDamage.MockServiceAdapter

    alias PropertyDamage.Test.Lockstep

    @impl true
    def setup(config) do
      Lockstep.notify(config, {:mock_setup, config.name, self()})
      {:ok, config}
    end

    @impl true
    def teardown(_context), do: :ok

    @impl true
    def init_state, do: %{}

    @impl true
    def on_command(_command, state), do: state

    @impl true
    def handle_request(_request, _state), do: {:ok, %{}}
  end
end
