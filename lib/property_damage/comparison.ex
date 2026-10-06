defmodule PropertyDamage.Comparison do
  @moduledoc false
  # Boundary comparison: the variants of a run are compared only through the
  # `@compare` functions of the model's projections (boundary observations).
  #
  # At each root boundary an observation's schedule names, every variant
  # evaluates it on its own projection state, and each non-reference variant's
  # value is judged against the reference's by the observation's `using:`
  # predicate. When a side is pending or the values differ, the convergence
  # loop lets the variants catch up (drain and fold their queues, run their
  # async checks, re-read a probe root) and judges again, until every side
  # agrees or the convergence bound (`compare: [converge_within: ms]`)
  # expires. At the bound a side still pending did not converge, and ready
  # sides that still differ diverged.
  #
  # The bound starts when the last variant reached the boundary and is checked
  # between iterations, so an iteration that started before the bound runs to
  # its end (a probe re-read runs to its own per-command settle).

  alias PropertyDamage.{Equivalence, Failure, Model, Variant}

  # How often the loop drains the variants while it waits after a mutation
  # root (ms). A drain that delivers an event to a variant ends the wait at
  # once; this only bounds how late that delivery is noticed.
  @drain_tick_ms 5

  # The longest the loop goes without judging again when no drain delivered
  # anything, and the shortest time between two probe re-reads (ms).
  @interval_ms 50

  @typedoc "A boundary observation's key: its projection and its function name."
  @type key :: {module(), atom()}

  @typedoc "Per-key counters: boundaries compared at, boundaries waited at, time waited."
  @type counts :: PropertyDamage.Scheduler.compare_counts()

  # ==========================================================================
  # Declarations
  # ==========================================================================

  @doc false
  # Every boundary observation the model's projections declare, in projection
  # order, as `%{key:, schedule:}`.
  @spec observations(module()) :: [%{key: key(), schedule: map()}]
  def observations(model) do
    # `Model.projection_modules/1` reads the optional check_projections/0 with
    # function_exported?/3, which is false for a module not loaded yet.
    Code.ensure_loaded(model)

    for projection <- Model.projection_modules(model),
        Code.ensure_loaded?(projection),
        function_exported?(projection, :__compares__, 0),
        %{name: name, schedule: schedule} <- projection.__compares__() do
      %{key: {projection, name}, schedule: schedule}
    end
  end

  @doc false
  # Every declared key at zero.
  @spec zero_counts(module()) :: counts()
  def zero_counts(model) do
    Map.new(observations(model), fn %{key: key} -> {key, zero()} end)
  end

  @doc false
  @spec merge_counts(counts(), counts()) :: counts()
  def merge_counts(left, right) do
    Map.merge(left, right, fn _key, a, b ->
      %{
        compared_at: a.compared_at + b.compared_at,
        waited_at: a.waited_at + b.waited_at,
        waited_ms: a.waited_ms + b.waited_ms
      }
    end)
  end

  defp zero, do: %{compared_at: 0, waited_at: 0, waited_ms: 0}

  @doc false
  # The run-start check for a run of `target_count` targets. With two or more
  # targets the model must declare at least one `@compare` function, because
  # variants are compared through nothing else, and every `using:` must be a
  # 2-arity function. Raises `ArgumentError` otherwise.
  @spec check_model!(module(), pos_integer()) :: :ok
  def check_model!(_model, target_count) when target_count < 2, do: :ok

  def check_model!(model, _target_count) do
    case observations(model) do
      [] ->
        raise ArgumentError,
              "#{inspect(model)} declares no @compare function on any projection " <>
                "(command_sequence_projection/0 and check_projections/0), so its targets " <>
                "have nothing to be compared on. A run with two or more targets compares " <>
                "them only through boundary observations: mark a projection function " <>
                "`def name(state, root)` with `@compare`."

      observations ->
        Enum.each(observations, fn %{key: key} -> using!(key) end)
    end
  end

  # The `using:` predicate of `key`, which must be a 2-arity function.
  defp using!({projection, name} = key) do
    using = projection.__compare_using__(name)

    if is_function(using, 2) do
      using
    else
      raise ArgumentError,
            "@compare using: of #{label(key)} must be a 2-arity function " <>
              "`fn reference_value, variant_value -> ... end`, got: #{inspect(using)}"
    end
  end

  @doc false
  # `Projection.function`, the label a report prints for a key.
  @spec label(key()) :: String.t()
  def label({projection, name}), do: "#{inspect(projection)}.#{name}"

  # ==========================================================================
  # Schedule
  # ==========================================================================

  @doc false
  # The keys to compare at each root of `commands`, as a tuple indexed by
  # root. A key is compared at a boundary once, whether its schedule names
  # that root, the final boundary, or both.
  @spec plan([%{key: key(), schedule: map()}], [struct()]) :: tuple()
  def plan(observations, commands) do
    last = length(commands) - 1
    modules = Enum.map(commands, & &1.__struct__)

    modules
    |> Enum.with_index()
    |> Enum.map_reduce(%{}, fn {module, root}, seen ->
      seen = Map.update(seen, module, 1, &(&1 + 1))

      keys =
        for %{key: key, schedule: schedule} <- observations,
            fires?(schedule, root, module, seen, root == last),
            do: key

      {keys, seen}
    end)
    |> elem(0)
    |> List.to_tuple()
  end

  defp fires?(%{end: true}, _root, _module, _seen, true), do: true

  defp fires?(%{roots: roots}, root, module, seen, _last?),
    do: root_fires?(roots, root, module, seen)

  defp root_fires?(:all, _root, _module, _seen), do: true
  defp root_fires?(:none, _root, _module, _seen), do: false
  defp root_fires?({:every, n}, root, _module, _seen), do: rem(root + 1, n) == 0
  defp root_fires?({:modules, modules}, _root, module, _seen), do: module in modules

  defp root_fires?({:every_of, n, modules}, _root, module, seen),
    do: module in modules and rem(Map.fetch!(seen, module), n) == 0

  # ==========================================================================
  # One boundary
  # ==========================================================================

  @doc false
  # Compares `keys` at `root` across `variants` (the scheduler's variant maps,
  # reference first), entering the convergence loop when a side is pending or
  # the values differ.
  #
  # Options: `:within` (the convergence bound, ms), `:concurrency`, `:final`
  # (the variants already finalized: no queue can deliver any more), `:probe`
  # (the root is a `:probe` command, re-read on every iteration, at the final
  # boundary too) and
  # `:arrived_at` (monotonic ms when the last variant reached the boundary).
  #
  # Returns `{:agree, counts}` or `{:failed, target, root, reason, counts}`,
  # where `reason` is a `%PropertyDamage.Failure{}` (a divergence, a failure
  # to converge, or a check failure: an observation or predicate that raised,
  # or a failure the variant reported while catching up).
  @spec compare(non_neg_integer(), struct(), [key()], [map()], keyword()) ::
          {:agree, counts()} | {:failed, struct(), non_neg_integer() | nil, Failure.t(), counts()}
  def compare(_root, _command, [], _variants, _opts), do: {:agree, %{}}

  def compare(root, command, keys, variants, opts) do
    arrived_at = Keyword.fetch!(opts, :arrived_at)

    loop = %{
      root: root,
      command: command,
      keys: keys,
      usings: Map.new(keys, &{&1, using!(&1)}),
      variants: variants,
      within: Keyword.fetch!(opts, :within),
      concurrency: Keyword.fetch!(opts, :concurrency),
      final: Keyword.get(opts, :final, false),
      probe: Keyword.get(opts, :probe, false),
      arrived_at: arrived_at,
      deadline: arrived_at + Keyword.fetch!(opts, :within),
      waited: MapSet.new(),
      last_read: nil
    }

    iterate(loop)
  end

  defp iterate(loop) do
    case judge(loop) do
      {:ok, verdicts} ->
        disagreeing = for {key, verdict} <- verdicts, verdict != :agree, do: key
        loop = %{loop | waited: MapSet.union(loop.waited, MapSet.new(disagreeing))}

        cond do
          disagreeing == [] -> {:agree, counts(loop)}
          now() >= loop.deadline -> bound_expired(loop, verdicts)
          true -> loop |> catch_up() |> continue()
        end

      {:failed, target, root, reason} ->
        {:failed, target, root, reason, counts(loop)}
    end
  end

  defp continue({:ok, loop}), do: iterate(loop)

  defp continue({:failed, loop, target, root, reason}),
    do: {:failed, target, root, reason, counts(loop)}

  defp counts(loop) do
    waited_ms = now() - loop.arrived_at

    Map.new(loop.keys, fn key ->
      if MapSet.member?(loop.waited, key),
        do: {key, %{compared_at: 1, waited_at: 1, waited_ms: waited_ms}},
        else: {key, %{compared_at: 1, waited_at: 0, waited_ms: 0}}
    end)
  end

  # At the bound: the first key (in declaration order) that does not agree
  # names the failure; a pending side wins over a difference in that key.
  defp bound_expired(loop, verdicts) do
    waited_ms = now() - loop.arrived_at

    {key, verdict} = Enum.find(verdicts, fn {_key, verdict} -> verdict != :agree end)

    {target, reason} =
      case verdict do
        {:pending, target, pending_reason} ->
          {target,
           Failure.did_not_converge(%{
             key: key,
             root: loop.root,
             command: loop.command,
             reason: pending_reason,
             waited_ms: waited_ms,
             within_ms: loop.within
           })}

        {:differ, target, reference_value, variant_value, mismatch} ->
          {target,
           Failure.diverged(%{
             key: key,
             root: loop.root,
             command: loop.command,
             reference_value: reference_value,
             variant_value: variant_value,
             mismatch: mismatch
           })}
      end

    {:failed, target, loop.root, reason, counts(loop)}
  end

  # ==========================================================================
  # Evaluating and judging
  # ==========================================================================

  # Evaluates every key in every variant and judges each key. Returns
  # `{:ok, [{key, verdict}]}` in key order, where a verdict is `:agree`,
  # `{:pending, target, reason}` or `{:differ, target, reference, variant,
  # mismatch}`; or `{:failed, target, root, reason}` when an observation or a
  # predicate raised, or a variant reports a failure.
  defp judge(loop) do
    with {:ok, observed} <- observe_all(loop) do
      [{reference, reference_values} | others] = observed

      Enum.reduce_while(loop.keys, {:ok, []}, fn key, {:ok, verdicts} ->
        case judge_key(loop, key, {reference, Map.fetch!(reference_values, key)}, others) do
          {:failed, _target, _root, _reason} = failed -> {:halt, failed}
          verdict -> {:cont, {:ok, verdicts ++ [{key, verdict}]}}
        end
      end)
    end
  end

  defp observe_all(loop) do
    loop.variants
    |> Enum.reduce_while({:ok, []}, fn variant, {:ok, observed} ->
      case Variant.observe(variant.pid, loop.root, loop.keys) do
        {:ok, values} ->
          case Enum.find(loop.keys, &match?({:raised, _}, Map.fetch!(values, &1))) do
            nil ->
              {:cont, {:ok, [{variant.target, values} | observed]}}

            key ->
              {:raised, exception} = Map.fetch!(values, key)
              {:halt, {:failed, variant.target, loop.root, Failure.check_failed(key, exception)}}
          end

        {:failed, %{root: root, reason: reason}} ->
          {:halt, {:failed, variant.target, root, reason}}
      end
    end)
    |> case do
      {:ok, observed} -> {:ok, Enum.reverse(observed)}
      failed -> failed
    end
  end

  defp judge_key(loop, key, {reference, reference_value}, others) do
    case reference_value do
      {:pending, reason} ->
        {:pending, reference, reason}

      {:value, reference_value} ->
        using = Map.fetch!(loop.usings, key)

        Enum.reduce_while(others, :agree, fn {target, values}, :agree ->
          case Map.fetch!(values, key) do
            {:pending, reason} ->
              {:halt, {:pending, target, reason}}

            {:value, value} ->
              case verdict(using, reference_value, value) do
                :match ->
                  {:cont, :agree}

                {:mismatch, mismatch} ->
                  {:halt, {:differ, target, reference_value, value, mismatch}}

                {:raised, exception} ->
                  {:halt, {:failed, target, loop.root, Failure.check_failed(key, exception)}}
              end
          end
        end)
    end
  end

  defp verdict(using, reference_value, value) do
    Equivalence.verdict(using, reference_value, value)
  rescue
    exception -> {:raised, exception}
  end

  # ==========================================================================
  # Catching up
  # ==========================================================================

  # One iteration of the loop. At a probe root every variant re-reads the
  # root, no sooner than the interval after the previous re-read started; the
  # final boundary is no exception, since finalizing stopped the variants'
  # pollers, not the systems they read. At a mutation root the loop drains the
  # variants until one of them received an event, the interval passed, or the
  # bound expired; at the final boundary after a mutation root nothing can
  # change any more, so the loop only waits for the bound.
  defp catch_up(%{probe: true} = loop), do: reread(loop)

  defp catch_up(%{final: true} = loop) do
    Process.sleep(max(loop.deadline - now(), 0))
    {:ok, loop}
  end

  defp catch_up(loop), do: drain_until_delivery(loop)

  defp reread(loop) do
    if loop.last_read, do: Process.sleep(max(loop.last_read + @interval_ms - now(), 0))
    loop = %{loop | last_read: now()}

    case on_each_variant(loop, &Variant.catch_up(&1, loop.root, :reread)) do
      {:ok, _delivered} -> {:ok, loop}
      {:failed, target, root, reason} -> {:failed, loop, target, root, reason}
    end
  end

  defp drain_until_delivery(loop), do: drain_until_delivery(loop, now() + @interval_ms)

  defp drain_until_delivery(loop, until) do
    case on_each_variant(loop, &Variant.catch_up(&1, loop.root, :drain)) do
      {:ok, delivered} when delivered > 0 ->
        {:ok, loop}

      {:ok, 0} ->
        stop = min(until, loop.deadline)

        if now() >= stop do
          {:ok, loop}
        else
          Process.sleep(min(@drain_tick_ms, stop - now()))
          drain_until_delivery(loop, until)
        end

      {:failed, target, root, reason} ->
        {:failed, loop, target, root, reason}
    end
  end

  # Calls `fun` with each variant's pid, one after another under `:serial`
  # and all at once under `:parallel`. Returns `{:ok, total delivered}` or the
  # first failure in target order.
  defp on_each_variant(loop, fun) do
    replies =
      case loop.concurrency do
        :serial ->
          Enum.map(loop.variants, &{&1.target, fun.(&1.pid)})

        :parallel ->
          loop.variants
          |> Enum.map(fn variant -> Task.async(fn -> {variant.target, fun.(variant.pid)} end) end)
          |> Task.await_many(:infinity)
      end

    Enum.reduce_while(replies, {:ok, 0}, fn
      {_target, {:ok, delivered}}, {:ok, total} ->
        {:cont, {:ok, total + delivered}}

      {target, {:failed, %{root: root, reason: reason}}}, _acc ->
        {:halt, {:failed, target, root, reason}}
    end)
  end

  defp now, do: System.monotonic_time(:millisecond)
end
