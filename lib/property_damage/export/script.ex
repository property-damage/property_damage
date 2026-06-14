defmodule PropertyDamage.Export.Script do
  @moduledoc """
  Script generation dispatcher.

  Generates standalone reproduction scripts in multiple languages.
  Scripts can be run without PropertyDamage installed.

  ## Supported Languages

  - `:elixir` - Elixir script with Req HTTP client
  - `:curl` - Bash script with curl commands
  - `:python` - Python script with requests library

  ## Usage

      script = PropertyDamage.Export.Script.generate(failure, :curl,
        base_url: "http://localhost:4000",
        adapter: MyHTTPAdapter
      )

      File.write!("reproduce.sh", script)
  """

  alias PropertyDamage.Export.Script.{Curl, Python}
  alias PropertyDamage.Export.Script.Elixir, as: ElixirScript
  alias PropertyDamage.FailureReport

  @type language :: :elixir | :curl | :python

  @doc """
  Generates a standalone script from a failure report.

  ## Options

  - `:base_url` - Base URL for HTTP calls (required)
  - `:adapter` - Adapter module for HTTPSpec (optional)
  - `:env_var` - Environment variable name for base URL (default: "BASE_URL")
  - `:verbose` - Include extra comments (default: true)
  """
  @spec generate(FailureReport.t(), language(), keyword()) :: String.t()
  def generate(%FailureReport{} = report, language, opts \\ []) do
    case language do
      :curl -> Curl.generate(report, opts)
      :bash -> Curl.generate(report, opts)
      :elixir -> ElixirScript.generate(report, opts)
      :python -> Python.generate(report, opts)
    end
  end

  @doc """
  Returns the file extension for a script language.
  """
  @spec extension(language()) :: String.t()
  def extension(:elixir), do: ".exs"
  def extension(:curl), do: ".sh"
  def extension(:bash), do: ".sh"
  def extension(:python), do: ".py"

  @doc """
  Returns all supported script languages.
  """
  @spec languages() :: [language()]
  def languages, do: [:elixir, :curl, :python]
end
