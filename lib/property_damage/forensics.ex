defmodule PropertyDamage.Forensics do
  @moduledoc """
  Replay production event logs through model projections for incident analysis.

  When a production incident occurs, you can use Forensics to replay the actual
  events through your test projections. This reuses all your invariant checks
  and state tracking to pinpoint exactly when and how something went wrong.

  ## Why Forensics?

  Instead of manually tracing through logs, let the same models and projections
  that verify correctness during testing analyze production behavior:

  1. **Same invariant checks** - Production events are verified against the same
     assertions used in property tests
  2. **State reconstruction** - See exactly what state the system was in at each step
  3. **Failure localization** - Pinpoint the exact event that violated an invariant
  4. **Reusable models** - No need to write separate incident analysis code

  ## Usage

      # Fetch events from your observability system
      {:ok, events} = ProductionLogs.fetch(trace_id: "abc123")

      # Replay through model projections
      result = PropertyDamage.Forensics.analyze(
        events: events,
        model: OrderModel,
        event_mapping: MyEventMapping  # Optional: translate production format
      )

      case result do
        {:ok, %{final_state: state}} ->
          IO.puts("No invariant violations detected")

        {:error, failure} ->
          IO.puts("Found violation at step \#{failure.failure_step}")
          IO.puts(PropertyDamage.Forensics.format_report(failure))
      end

  ## Event Mapping

  Production events often have different field names or structures. Implement
  an event mapping module to translate them:

      defmodule MyEventMapping do
        @behaviour PropertyDamage.Forensics.EventMapping

        @impl true
        def map(%{"type" => "order.created", "payload" => p}) do
          {:ok, %OrderCreated{order_ref: p["order_id"], amount: p["total"]}}
        end

        def map(_), do: :skip
      end

  ## Limitations

  - Events must be self-describing (contain enough context to reconstruct state)
  - Projections receive `ctx.command = nil` since there's no command in forensic mode
  - Event ordering must match production ordering
  """

  @typedoc """
  Successful analysis result.
  """
  @type success_result :: %{
          final_state: map(),
          events_processed: non_neg_integer(),
          projections: %{module() => term()}
        }

  @typedoc """
  Failed analysis result.
  """
  @type failure_result :: %{
          failure_reason: term(),
          failure_step: non_neg_integer(),
          event_at_failure: struct() | map(),
          state_before: map(),
          state_after: map(),
          events_leading_to_failure: [struct() | map()]
        }

  @typedoc """
  Analysis result - either success or failure.
  """
  @type analysis_result :: {:ok, success_result()} | {:error, failure_result()}

  @doc """
  Analyze a sequence of production events against a model.

  Replays events through the model's projections, running assertion checks
  after each event. Stops at the first invariant violation (by default).

  ## Options

  - `:model` - The model module (required)
  - `:event_mapping` - Module to translate production events (optional)
  - `:stop_on_first_failure` - Stop at first invariant violation (default: true)
  - `:projections` - Override which assertion projections to use (default: model's)

  ## Returns

  - `{:ok, success_result}` - All events processed without violations
  - `{:error, failure_result}` - An invariant was violated

  ## Examples

      # Basic usage
      Forensics.analyze(events: events, model: MyModel)

      # With event mapping
      Forensics.analyze(
        events: production_events,
        model: MyModel,
        event_mapping: MyMapper
      )

      # Continue past failures
      Forensics.analyze(
        events: events,
        model: MyModel,
        stop_on_first_failure: false
      )
  """
  @spec analyze(keyword()) :: analysis_result()
  def analyze(opts) do
    events = Keyword.fetch!(opts, :events)
    model = Keyword.fetch!(opts, :model)
    mapping = Keyword.get(opts, :event_mapping)
    stop_early = Keyword.get(opts, :stop_on_first_failure, true)

    # Initialize projections
    state_projection = model.state_projection()

    assertion_projections =
      Keyword.get(opts, :projections, model.assertion_projections())

    all_projections = [state_projection | assertion_projections]

    initial_projections =
      for projection <- all_projections, into: %{} do
        {projection, projection.init()}
      end

    initial_state = %{
      projections: initial_projections,
      events_processed: 0
    }

    # Map events if mapping provided
    mapped_events = maybe_map_events(events, mapping)

    # Process events sequentially
    result =
      mapped_events
      |> Enum.with_index()
      |> Enum.reduce_while({:ok, initial_state, []}, fn {event, index}, {:ok, state, history} ->
        # Skip nil events (from mapping)
        if is_nil(event) do
          {:cont, {:ok, state, history}}
        else
          process_event(event, index, state, history, model, assertion_projections, stop_early)
        end
      end)

    finalize_result(result)
  end

  defp process_event(event, index, state, history, model, assertion_projections, stop_early) do
    # Apply event to all projections
    new_projections =
      for {projection, projection_state} <- state.projections, into: %{} do
        {projection, projection.apply(projection_state, event)}
      end

    new_state = %{
      projections: new_projections,
      events_processed: index + 1
    }

    # Run checks on assertion projections
    check_ctx = %{
      command: nil,
      events: [event],
      command_index: nil,
      step_count: index + 1,
      projections: new_projections,
      branch_id: nil
    }

    case run_checks(model, assertion_projections, new_projections, check_ctx) do
      :ok ->
        {:cont, {:ok, new_state, history ++ [event]}}

      {:error, check_name, reason} when stop_early ->
        {:halt,
         {:error,
          %{
            failure_reason: {:check_failed, check_name, reason},
            failure_step: index,
            event_at_failure: event,
            state_before: state.projections,
            state_after: new_projections,
            events_leading_to_failure: history ++ [event]
          }}}

      {:error, _check_name, _reason} ->
        # Continue past failure if stop_early is false
        {:cont, {:ok, new_state, history ++ [event]}}
    end
  end

  defp finalize_result({:ok, state, _history}) do
    state_projection_key =
      Enum.find(Map.keys(state.projections), fn mod ->
        not function_exported?(mod, :__checks__, 0)
      end)

    {:ok,
     %{
       final_state: Map.get(state.projections, state_projection_key),
       events_processed: state.events_processed,
       projections: state.projections
     }}
  end

  defp finalize_result({:error, failure}), do: {:error, failure}

  defp maybe_map_events(events, nil), do: events

  defp maybe_map_events(events, mapping) do
    Enum.flat_map(events, fn event ->
      case mapping.map(event) do
        {:ok, mapped} -> [mapped]
        :skip -> []
        {:skip, _reason} -> []
      end
    end)
  end

  defp run_checks(_model, assertion_projections, projections, check_ctx) do
    Enum.reduce_while(assertion_projections, :ok, fn projection, :ok ->
      projection_state = Map.get(projections, projection)

      # Get checks for this projection
      checks =
        if function_exported?(projection, :__checks__, 0) do
          projection.__checks__()
        else
          []
        end

      case run_projection_checks(projection, projection_state, checks, check_ctx) do
        :ok -> {:cont, :ok}
        {:error, check_name, reason} -> {:halt, {:error, check_name, reason}}
      end
    end)
  end

  defp run_projection_checks(_projection, _projection_state, [], _check_ctx), do: :ok

  defp run_projection_checks(projection, projection_state, [check | rest], check_ctx) do
    # Only run checks that trigger on :always (forensics has no commands)
    if should_run_check?(check, check_ctx) do
      case projection.check(check.name, projection_state, check_ctx) do
        :ok ->
          run_projection_checks(projection, projection_state, rest, check_ctx)

        {:error, reason} ->
          {:error, check.name, reason}
      end
    else
      run_projection_checks(projection, projection_state, rest, check_ctx)
    end
  end

  defp should_run_check?(%{trigger: :always}, _ctx), do: true

  defp should_run_check?(%{trigger: [{:after, modules}]}, ctx) do
    # In forensic mode, we only have events, no commands
    event_modules = Enum.map(ctx.events, &get_module/1)
    Enum.any?(modules, fn mod -> mod in event_modules end)
  end

  defp should_run_check?(_, _ctx), do: false

  defp get_module(%{__struct__: mod}), do: mod
  defp get_module(_), do: nil

  @doc """
  Format a failure report as a human-readable string.

  ## Example

      {:error, failure} = Forensics.analyze(events: events, model: MyModel)
      IO.puts(Forensics.format_report(failure))

      # Output:
      # ═══════════════════════════════════════════════════════════════════
      # FORENSIC ANALYSIS: INVARIANT VIOLATION DETECTED
      # ═══════════════════════════════════════════════════════════════════
      #
      # FAILURE OCCURRED AT: Event #47
      # ...
  """
  @spec format_report(failure_result()) :: String.t()
  def format_report(failure) do
    """
    ═══════════════════════════════════════════════════════════════════════
    FORENSIC ANALYSIS: INVARIANT VIOLATION DETECTED
    ═══════════════════════════════════════════════════════════════════════

    FAILURE OCCURRED AT: Event ##{failure.failure_step}

    EVENT AT FAILURE:
    #{inspect(failure.event_at_failure, pretty: true)}

    FAILURE REASON:
    #{format_failure_reason(failure.failure_reason)}

    EVENTS LEADING TO FAILURE:
    #{format_event_history(failure.events_leading_to_failure)}

    STATE BEFORE FAILURE:
    #{inspect(failure.state_before, pretty: true, limit: 20)}

    STATE AFTER FAILURE:
    #{inspect(failure.state_after, pretty: true, limit: 20)}
    ═══════════════════════════════════════════════════════════════════════
    """
  end

  defp format_failure_reason({:check_failed, check_name, reason}) do
    "Check '#{check_name}' failed: #{inspect(reason)}"
  end

  defp format_failure_reason(other), do: inspect(other)

  defp format_event_history(events) do
    events
    |> Enum.with_index()
    |> Enum.map(fn {event, idx} ->
      "  [#{idx}] #{format_event(event)}"
    end)
    |> Enum.join("\n")
  end

  defp format_event(%{__struct__: mod} = event) do
    fields =
      event
      |> Map.from_struct()
      |> Enum.filter(fn {_k, v} -> not is_nil(v) end)
      |> Enum.map(fn {k, v} -> "#{k}: #{inspect(v, limit: 3)}" end)
      |> Enum.join(", ")

    "#{inspect(mod)} {#{fields}}"
  end

  defp format_event(event), do: inspect(event, limit: 50)

  @doc """
  Generate a regression test from a forensic failure.

  Creates Elixir code that can be added to your test suite to reproduce
  the failure scenario with the exact events from production.

  ## Example

      {:error, failure} = Forensics.analyze(events: events, model: MyModel)
      test_code = Forensics.generate_regression_test(failure, MyModel)
      File.write!("test/regressions/incident_2025_01_15_test.exs", test_code)
  """
  @spec generate_regression_test(failure_result(), module()) :: String.t()
  def generate_regression_test(failure, model) do
    events_code =
      failure.events_leading_to_failure
      |> Enum.map(&event_to_code/1)
      |> Enum.join(",\n      ")

    """
    defmodule #{model}.RegressionTest do
      use ExUnit.Case

      @moduledoc \"\"\"
      Regression test generated from production incident.
      Generated at: #{DateTime.utc_now()}
      Failure at event index: #{failure.failure_step}
      \"\"\"

      test "regression: #{format_check_name(failure.failure_reason)}" do
        events = [
          #{events_code}
        ]

        result = PropertyDamage.Forensics.analyze(
          events: events,
          model: #{inspect(model)}
        )

        # This should fail with the same error
        assert {:error, failure} = result
        assert failure.failure_step == #{failure.failure_step}
      end
    end
    """
  end

  defp event_to_code(%{__struct__: mod} = event) do
    fields =
      event
      |> Map.from_struct()
      |> Enum.filter(fn {_k, v} -> not is_nil(v) end)
      |> Enum.map(fn {k, v} -> "#{k}: #{inspect(v)}" end)
      |> Enum.join(", ")

    "%#{inspect(mod)}{#{fields}}"
  end

  defp event_to_code(event), do: inspect(event)

  defp format_check_name({:check_failed, name, _}), do: "#{name} failure"
  defp format_check_name(_), do: "unknown failure"
end
