defmodule Mix.Tasks.Pd.Integration do
  @moduledoc """
  Run PropertyDamage integration tests against a live service.

  This task runs stateful property-based tests against a running service,
  with support for health checks, reporting, and failure persistence.

  ## Usage

      mix pd.integration --model MyModel --adapter MyAdapter --url http://localhost:4000

  ## Required Options

      --model     The model module (e.g., ToyBankTest.Model)
      --adapter   The adapter module (e.g., ToyBankTest.Adapters.HTTPAdapter)
      --url       Base URL of the service under test

  ## Optional Options

      --runs          Number of test runs (default: 100)
      --commands      Max commands per run (default: 50)
      --health        Health check URL (default: {url}/health or {url}/api/health)
      --report        Report format: terminal, markdown, junit, json
      --report-path   Path for report file (required for non-terminal formats)
      --save-failures Directory to save failure files
      --stop-on-fail  Stop on first failure
      --hunt          Bug hunt mode: stop after finding N unique bugs
      --verbose       Show detailed progress (default: true)
      --quiet         Suppress progress output

  ## Examples

      # Basic integration test
      mix pd.integration \\
        --model ToyBankTest.Model \\
        --adapter ToyBankTest.Adapters.HTTPAdapter \\
        --url http://localhost:4555

      # With JUnit report for CI
      mix pd.integration \\
        --model ToyBankTest.Model \\
        --adapter ToyBankTest.Adapters.HTTPAdapter \\
        --url http://localhost:4555 \\
        --runs 500 \\
        --report junit \\
        --report-path reports/integration.xml

      # Bug hunting mode
      mix pd.integration \\
        --model ToyBankTest.Model \\
        --adapter ToyBankTest.Adapters.HTTPAdapter \\
        --url http://localhost:4555 \\
        --hunt 10 \\
        --save-failures discovered_bugs/

      # Quick smoke test
      mix pd.integration \\
        --model ToyBankTest.Model \\
        --adapter ToyBankTest.Adapters.HTTPAdapter \\
        --url http://localhost:4555 \\
        --runs 10 \\
        --stop-on-fail

  ## Exit Codes

      0  - All tests passed
      1  - One or more tests failed
      2  - Configuration or setup error

  ## Environment Variables

      PROPERTYDAMAGE_BASE_URL  - Default base URL if --url not provided
      PROPERTYDAMAGE_RUNS      - Default number of runs
  """

  use Mix.Task

  @shortdoc "Run integration tests against a live service"

  @switches [
    model: :string,
    adapter: :string,
    url: :string,
    runs: :integer,
    commands: :integer,
    health: :string,
    report: :string,
    report_path: :string,
    save_failures: :string,
    stop_on_fail: :boolean,
    hunt: :integer,
    verbose: :boolean,
    quiet: :boolean
  ]

  @impl true
  def run(args) do
    # Start applications
    Mix.Task.run("app.start")

    # Parse arguments
    {opts, _, invalid} = OptionParser.parse(args, strict: @switches)

    if invalid != [] do
      IO.puts("Unknown options: #{inspect(invalid)}")
      print_usage()
      System.halt(2)
    end

    # Validate required options
    model = get_required_opt(opts, :model, "MODEL")
    adapter = get_required_opt(opts, :adapter, "ADAPTER")
    url = get_opt_with_env(opts, :url, "PROPERTYDAMAGE_BASE_URL", "URL")

    # Parse modules
    model_module = parse_module(model)
    adapter_module = parse_module(adapter)

    # Validate modules exist
    validate_module(model_module, "Model")
    validate_module(adapter_module, "Adapter")

    # Build options
    runs = opts[:runs] || get_env_int("PROPERTYDAMAGE_RUNS") || 100
    commands = opts[:commands] || 50
    verbose = if opts[:quiet], do: false, else: Keyword.get(opts, :verbose, true)

    integration_opts = [
      model: model_module,
      adapter: adapter_module,
      adapter_config: %{base_url: url},
      max_runs: runs,
      max_commands: commands,
      verbose: verbose,
      stop_on_failure: opts[:stop_on_fail] || false
    ]

    # Add health check
    health_url = opts[:health] || guess_health_url(url)

    integration_opts =
      Keyword.put(integration_opts, :health_check, %{
        url: health_url,
        timeout_ms: 30_000,
        retries: 30
      })

    # Add save failures
    integration_opts =
      if opts[:save_failures] do
        Keyword.put(integration_opts, :save_failures, opts[:save_failures])
      else
        integration_opts
      end

    # Add report
    integration_opts =
      if opts[:report] do
        format = String.to_atom(opts[:report])

        report_opts =
          if format == :terminal do
            %{format: format}
          else
            path = opts[:report_path] || default_report_path(format)
            ensure_parent_dir(path)
            %{format: format, path: path}
          end

        Keyword.put(integration_opts, :report, report_opts)
      else
        integration_opts
      end

    # Run tests
    result =
      if opts[:hunt] do
        PropertyDamage.Integration.hunt_bugs(
          Keyword.merge(integration_opts,
            stop_after: opts[:hunt],
            max_runs: :unlimited,
            save_to: opts[:save_failures]
          )
        )
      else
        PropertyDamage.Integration.run(integration_opts)
      end

    # Exit with appropriate code
    case result do
      {:ok, %{success: true}} ->
        System.halt(0)

      {:ok, %{success: false}} ->
        System.halt(1)

      {:ok, bugs} when is_list(bugs) ->
        # Bug hunt mode
        if bugs != [], do: System.halt(1), else: System.halt(0)

      {:error, _} ->
        System.halt(1)
    end
  end

  defp get_required_opt(opts, key, _name) do
    case Keyword.get(opts, key) do
      nil ->
        IO.puts("Error: --#{key} is required")
        print_usage()
        System.halt(2)

      value ->
        value
    end
  end

  defp get_opt_with_env(opts, key, env_var, _name) do
    case Keyword.get(opts, key) || System.get_env(env_var) do
      nil ->
        IO.puts("Error: --#{key} is required (or set #{env_var})")
        print_usage()
        System.halt(2)

      value ->
        value
    end
  end

  defp get_env_int(var) do
    case System.get_env(var) do
      nil -> nil
      val -> String.to_integer(val)
    end
  end

  defp parse_module(string) do
    string
    |> String.replace(~r/^Elixir\./, "")
    |> then(&("Elixir." <> &1))
    |> String.to_atom()
  end

  defp validate_module(module, type) do
    unless Code.ensure_loaded?(module) do
      IO.puts("Error: #{type} module #{inspect(module)} not found")
      IO.puts("Make sure the module is compiled and available")
      System.halt(2)
    end
  end

  defp guess_health_url(base_url) do
    # Try common health check paths
    cond do
      String.ends_with?(base_url, "/") ->
        base_url <> "api/health"

      true ->
        base_url <> "/api/health"
    end
  end

  defp default_report_path(:markdown), do: "reports/integration_#{timestamp()}.md"
  defp default_report_path(:junit), do: "reports/integration_#{timestamp()}.xml"
  defp default_report_path(:json), do: "reports/integration_#{timestamp()}.json"
  defp default_report_path(_), do: "reports/integration_#{timestamp()}.txt"

  defp timestamp do
    DateTime.utc_now()
    |> DateTime.to_iso8601(:basic)
    |> String.replace(~r/[:\-]/, "")
    |> String.slice(0, 15)
  end

  defp ensure_parent_dir(path) do
    path |> Path.dirname() |> File.mkdir_p!()
  end

  defp print_usage do
    IO.puts("""

    Usage: mix pd.integration --model MODEL --adapter ADAPTER --url URL [OPTIONS]

    Required:
      --model       Model module (e.g., ToyBankTest.Model)
      --adapter     Adapter module (e.g., ToyBankTest.Adapters.HTTPAdapter)
      --url         Base URL of service (e.g., http://localhost:4555)

    Options:
      --runs N          Number of test runs (default: 100)
      --commands N      Max commands per run (default: 50)
      --health URL      Health check URL
      --report FORMAT   Report format: terminal, markdown, junit, json
      --report-path     Path for report file
      --save-failures   Directory to save failures
      --stop-on-fail    Stop on first failure
      --hunt N          Bug hunt mode: find N unique bugs
      --quiet           Suppress progress output

    Examples:
      mix pd.integration --model ToyBankTest.Model \\
                         --adapter ToyBankTest.Adapters.HTTPAdapter \\
                         --url http://localhost:4555 \\
                         --runs 100

      mix pd.integration --model ToyBankTest.Model \\
                         --adapter ToyBankTest.Adapters.HTTPAdapter \\
                         --url http://localhost:4555 \\
                         --hunt 10 --save-failures bugs/
    """)
  end
end
