defmodule PropertyDamage.ExUnit do
  alias PropertyDamage.FailureReport

  @moduledoc """
  ExUnit integration for PropertyDamage property tests.

  This module provides macros for writing property-based tests that integrate
  seamlessly with ExUnit. Tests can be defined using module attributes for
  configuration, with individual test overrides as needed.

  ## Usage

      defmodule MySystemTest do
        use ExUnit.Case
        use PropertyDamage.ExUnit

        property_damage "system maintains invariants",
          model: MyApp.TestModel,
          adapter: MyApp.TestAdapter,
          max_commands: 50,
          max_runs: 100

        property_damage "handles concurrent access",
          model: MyApp.TestModel,
          adapter: MyApp.ConcurrentAdapter,
          max_commands: 100
      end

  ## Test Options

  Options passed to `property_damage/2`:

  **Required:**
  - `:model` - Model module (required)
  - `:adapter` - Adapter module (required)

  **Optional:** every other `PropertyDamage.run/1` option is forwarded as-is,
  including:
  - `:max_commands` - Max commands per sequence (default: 50)
  - `:max_runs` - Number of test sequences (default: 100)
  - `:seed` - Fixed seed for reproducibility
  - `:injector_adapters` - List of injector adapter modules (default: [])
  - `:shrink` - Whether to shrink failures (default: true)
  - `:validate` - Whether to validate config (default: true)
  - `:adapter_config` - Config passed to adapter.setup/1 (default: %{})
  - `:verbose`, `:assertion_mode`, `:branching`, `:stutter`,
    `:external_markers`, `:on_failure`, and the rest of the `run/1` surface

  Defaults are applied by `run/1` itself; a `nil` `:seed` is dropped so the
  run picks a random seed.

  ## Failure Formatting

  When a property test fails, the output includes:

  1. The seed for reproducing the failure
  2. The original command sequence
  3. The shrunk (minimal) command sequence
  4. The failure reason
  5. Instructions for reproducing with the same seed

  ## Example Failure Output

      1) property system maintains invariants
         Failure with seed: 12345

         Original sequence (5 commands):
           [%CreateItem{...}, %ViewItem{...}, ...]

         Shrunk sequence (2 commands):
           [%CreateItem{quantity: 101}]

         Failed at command #0:
           #PropertyDamage.Failure<assertion_failed :quantity_limit "Quantity 101 exceeds limit">

         Reproduce with: seed: 12345
  """

  @doc """
  Use this module to enable PropertyDamage test macros.

  Requires `use ExUnit.Case` to be called first.

  ## Example

      defmodule MyTest do
        use ExUnit.Case
        use PropertyDamage.ExUnit

        @model MyModel
        @adapter MyAdapter

        property_damage "test name" do
          max_runs: 10
        end
      end
  """
  defmacro __using__(_opts) do
    quote do
      import PropertyDamage.ExUnit, only: [property_damage: 1, property_damage: 2]
    end
  end

  @doc """
  Define a property-based test.

  Creates an ExUnit test that generates and executes command sequences,
  checking for invariant violations.

  ## Parameters

  - `name` - Test name (string)
  - `opts` - Options keyword list (see module docs for available options)

  ## Examples

      # Basic usage
      property_damage "basic test",
        model: MyModel,
        adapter: MyAdapter

      # With options
      property_damage "custom test",
        model: MyModel,
        adapter: MyAdapter,
        max_commands: 100,
        max_runs: 50

      # With fixed seed for reproduction
      property_damage "reproducible test",
        model: MyModel,
        adapter: MyAdapter,
        seed: 12345
  """
  defmacro property_damage(name, opts \\ []) do
    quote do
      test unquote(name) do
        run_opts = PropertyDamage.ExUnit.build_run_opts(unquote(opts))

        case PropertyDamage.run(run_opts) do
          {:ok, _stats} ->
            :ok

          {:error, report} ->
            flunk(PropertyDamage.ExUnit.format_failure(report))
        end
      end
    end
  end

  @doc """
  Assemble the options forwarded to `PropertyDamage.run/1` for a
  `property_damage/2` test.

  `:model` and `:adapter` are required (a missing one raises `KeyError` with a
  clear message); every other option is forwarded verbatim, so the full
  `run/1` surface (`verbose:`, `assertion_mode:`, `branching:`, `stutter:`,
  `external_markers:`, `on_failure:`, ...) is reachable from the ExUnit macro.
  `run/1` validates the result and applies its own defaults for any omitted
  option, so this function deliberately does not re-specify them. A `nil`
  `:seed` is dropped so `run/1` picks a random seed.
  """
  @spec build_run_opts(keyword()) :: keyword()
  def build_run_opts(opts) do
    # Required options: fail fast with a clear KeyError rather than letting
    # run/1 surface a less obvious validation message.
    Enum.each([:model, :adapter], &Keyword.fetch!(opts, &1))

    case Keyword.fetch(opts, :seed) do
      {:ok, nil} -> Keyword.delete(opts, :seed)
      _ -> opts
    end
  end

  @doc """
  Format a failure report for ExUnit output.

  Produces human-readable output with all relevant information for
  debugging and reproducing the failure.
  """
  @spec format_failure(FailureReport.t()) :: String.t()
  def format_failure(%FailureReport{} = report) do
    # Use the proper formatter for rich output
    FailureReport.Formatter.format(report, :terminal, color: true)
  end

  # Legacy support for old map-based reports
  def format_failure(report) when is_map(report) do
    # Check if this is the old format
    if Map.has_key?(report, :original_commands) do
      format_legacy_failure(report)
    else
      # Try to convert to string representation
      inspect(report, pretty: true, limit: 50)
    end
  end

  defp format_legacy_failure(report) do
    """
    Property test failed!

    Seed: #{report.seed}
    Run: #{report.run_number + 1}

    Original sequence (#{length(report.original_commands || [])} commands):
    #{format_commands(report.original_commands || [])}

    Shrunk sequence (#{length(report.shrunk_commands || [])} commands):
    #{format_commands(report.shrunk_commands || [])}

    Failed at command ##{report.failed_at_index}:
    #{format_failure_reason(report.failure_reason)}

    Shrinking: #{report.shrink_iterations} iterations in #{report.shrink_time_ms}ms

    To reproduce, add: seed: #{report.seed}
    """
  end

  defp format_commands([]), do: "  (empty)"

  defp format_commands(commands) do
    commands
    |> Enum.with_index()
    |> Enum.map_join("\n", fn {cmd, idx} -> "  #{idx}. #{inspect(cmd)}" end)
  end

  defp format_failure_reason(%PropertyDamage.Failure{} = failure) do
    case PropertyDamage.Failure.kind(failure) do
      kind when kind in [:assertion_failed, :projection_violation] ->
        "Check #{inspect(PropertyDamage.Failure.name(failure))} failed: " <>
          "#{inspect(PropertyDamage.Failure.detail(failure))}"

      :adapter_error ->
        "Adapter error: #{inspect(PropertyDamage.Failure.detail(failure))}"

      :placeholder_resolution ->
        "Placeholder resolution error: #{inspect(PropertyDamage.Failure.detail(failure))}"

      _ ->
        inspect(failure)
    end
  end

  defp format_failure_reason(other) do
    inspect(other)
  end
end
