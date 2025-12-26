defmodule PropertyDamage.Export do
  @moduledoc """
  Export failure reports to various portable formats.

  The Export module converts PropertyDamage failure reports into artifacts that can be
  shared, executed, and used for regression testing without requiring the full framework.

  ## Export Formats

  - **ExUnit** (`:exunit`) - Regression tests using PropertyDamage
  - **Scripts** - Standalone scripts in multiple languages:
    - `:elixir` - Elixir with Req HTTP client
    - `:curl` - Bash with curl commands
    - `:python` - Python with requests library
  - **LiveBook** (`:livebook`) - Interactive notebooks for exploration

  ## Usage

  ### Export to String

      # Generate ExUnit regression test
      test_code = PropertyDamage.Export.to_exunit(failure,
        model: MyModel,
        adapter: MyHTTPAdapter
      )

      # Generate standalone scripts
      curl_script = PropertyDamage.Export.to_script(failure, :curl,
        base_url: "http://localhost:4000",
        adapter: MyHTTPAdapter
      )

      python_script = PropertyDamage.Export.to_script(failure, :python,
        base_url: "http://localhost:4000",
        adapter: MyHTTPAdapter
      )

      # Generate LiveBook notebook
      notebook = PropertyDamage.Export.to_livebook(failure,
        base_url: "http://localhost:4000",
        adapter: MyHTTPAdapter
      )

  ### Export to File

      # Save individual format
      {:ok, path} = PropertyDamage.Export.save(failure, "exports/", :exunit)
      {:ok, path} = PropertyDamage.Export.save(failure, "exports/", {:script, :curl})
      {:ok, path} = PropertyDamage.Export.save(failure, "exports/", :livebook)

      # Save all formats at once
      {:ok, paths} = PropertyDamage.Export.save_all(failure, "exports/",
        base_url: "http://localhost:4000",
        adapter: MyHTTPAdapter
      )

  ## HTTPSpec for Script Generation

  For standalone scripts to work, the adapter should implement the optional `http_spec/2`
  callback that describes how commands map to HTTP calls. See `PropertyDamage.Export.HTTPSpec`
  for details.
  """

  alias PropertyDamage.FailureReport
  alias PropertyDamage.Export.{ExUnit, Script, LiveBook, Common}

  @type format ::
          :exunit
          | :livebook
          | {:script, Script.language()}

  # ============================================================================
  # Main API
  # ============================================================================

  @doc """
  Generates an ExUnit regression test from a failure report.

  ## Options

  - `:model` - Model module (defaults to report.model)
  - `:adapter` - Adapter module (defaults to report.adapter)
  - `:module_name` - Module name for the test
  - `:test_name` - Custom test name
  - `:adapter_config` - Adapter configuration map
  - `:expect_fixed` - If true, expect the test to pass (default: false)

  ## Example

      test_code = PropertyDamage.Export.to_exunit(failure,
        model: MyModel,
        adapter: MyHTTPAdapter
      )

      File.write!("test/regressions/seed_123_test.exs", test_code)
  """
  @spec to_exunit(FailureReport.t(), keyword()) :: String.t()
  def to_exunit(%FailureReport{} = report, opts \\ []) do
    ExUnit.generate(report, opts)
  end

  @doc """
  Generates a standalone script in the specified language.

  ## Supported Languages

  - `:elixir` - Elixir script with Req (runnable with `elixir script.exs`)
  - `:curl` - Bash script with curl (runnable with `bash script.sh`)
  - `:python` - Python script with requests (runnable with `python script.py`)

  ## Options

  - `:base_url` - Base URL for HTTP calls (required)
  - `:adapter` - Adapter module for HTTPSpec mapping (recommended)
  - `:env_var` - Environment variable name for base URL (default: "BASE_URL")
  - `:verbose` - Include extra comments (default: true)

  ## Example

      script = PropertyDamage.Export.to_script(failure, :curl,
        base_url: "http://localhost:4000",
        adapter: MyHTTPAdapter
      )

      File.write!("reproduce.sh", script)
  """
  @spec to_script(FailureReport.t(), Script.language(), keyword()) :: String.t()
  def to_script(%FailureReport{} = report, language, opts \\ []) do
    Script.generate(report, language, opts)
  end

  @doc """
  Generates a LiveBook notebook for interactive failure exploration.

  The notebook includes:
  - Setup with Mix.install for dependencies
  - Step-by-step command execution with state tracking
  - Exploration section for "what-if" experiments

  ## Options

  - `:base_url` - Base URL for HTTP calls (required)
  - `:adapter` - Adapter module for HTTPSpec mapping (recommended)
  - `:title` - Custom notebook title
  - `:include_exploration` - Include exploration section (default: true)
  - `:include_state_tracking` - Track model state (default: true)

  ## Example

      notebook = PropertyDamage.Export.to_livebook(failure,
        base_url: "http://localhost:4000",
        adapter: MyHTTPAdapter,
        title: "Investigating Balance Bug"
      )

      File.write!("investigation.livemd", notebook)
  """
  @spec to_livebook(FailureReport.t(), keyword()) :: String.t()
  def to_livebook(%FailureReport{} = report, opts \\ []) do
    LiveBook.generate(report, opts)
  end

  # ============================================================================
  # File Operations
  # ============================================================================

  @doc """
  Saves an export to a file.

  The filename is automatically generated based on the seed and format.

  ## Parameters

  - `report` - The failure report to export
  - `directory` - Directory to save the file in
  - `format` - Export format (`:exunit`, `{:script, :curl}`, `:livebook`, etc.)
  - `opts` - Format-specific options

  ## Example

      {:ok, path} = PropertyDamage.Export.save(failure, "exports/", :exunit)
      # => {:ok, "exports/reproduce_512902757.exs"}

      {:ok, path} = PropertyDamage.Export.save(failure, "scripts/", {:script, :curl},
        base_url: "http://localhost:4000"
      )
      # => {:ok, "scripts/reproduce_512902757.sh"}
  """
  @spec save(FailureReport.t(), Path.t(), format(), keyword()) ::
          {:ok, Path.t()} | {:error, term()}
  def save(%FailureReport{} = report, directory, format, opts \\ []) do
    content = generate(report, format, opts)
    filename = generate_filename(report, format)
    path = Path.join(directory, filename)

    case File.mkdir_p(directory) do
      :ok ->
        case File.write(path, content) do
          :ok -> {:ok, path}
          {:error, reason} -> {:error, {:write_failed, reason}}
        end

      {:error, reason} ->
        {:error, {:mkdir_failed, reason}}
    end
  end

  @doc """
  Saves exports in all formats to a directory.

  ## Options

  - `:base_url` - Base URL for HTTP calls (required for scripts/livebook)
  - `:adapter` - Adapter module for HTTPSpec
  - `:script_languages` - Languages for scripts (default: `[:elixir, :curl]`)
  - All other options are passed to individual generators

  ## Example

      {:ok, paths} = PropertyDamage.Export.save_all(failure, "exports/",
        base_url: "http://localhost:4000",
        adapter: MyHTTPAdapter,
        script_languages: [:elixir, :curl, :python]
      )

      # => {:ok, %{
      #   exunit: "exports/reproduce_512902757.exs",
      #   livebook: "exports/reproduce_512902757.livemd",
      #   script_elixir: "exports/reproduce_512902757.exs",
      #   script_curl: "exports/reproduce_512902757.sh",
      #   script_python: "exports/reproduce_512902757.py"
      # }}
  """
  @spec save_all(FailureReport.t(), Path.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def save_all(%FailureReport{} = report, directory, opts \\ []) do
    script_languages = Keyword.get(opts, :script_languages, [:elixir, :curl])

    formats = [:exunit, :livebook] ++ Enum.map(script_languages, &{:script, &1})

    results =
      Enum.reduce_while(formats, {:ok, %{}}, fn format, {:ok, paths} ->
        case save(report, directory, format, opts) do
          {:ok, path} ->
            key = format_key(format)
            {:cont, {:ok, Map.put(paths, key, path)}}

          {:error, _} = error ->
            {:halt, error}
        end
      end)

    results
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp generate(report, :exunit, opts), do: to_exunit(report, opts)
  defp generate(report, :livebook, opts), do: to_livebook(report, opts)
  defp generate(report, {:script, lang}, opts), do: to_script(report, lang, opts)

  defp generate_filename(report, :exunit) do
    Common.generate_filename(report, :exunit)
  end

  defp generate_filename(report, :livebook) do
    Common.generate_filename(report, :livebook)
  end

  defp generate_filename(report, {:script, lang}) do
    Common.generate_filename(report, lang)
  end

  defp format_key(:exunit), do: :exunit
  defp format_key(:livebook), do: :livebook
  defp format_key({:script, lang}), do: :"script_#{lang}"
end
