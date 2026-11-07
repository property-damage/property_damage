defmodule PropertyDamage.Failure.Naming do
  @moduledoc """
  Names and locations of a failure as text for a reader.

  Error messages, the progress printer, exports and the failure report all
  print these. They live here, below `PropertyDamage.FailureReport`, so a
  module that only needs to name a failure does not depend on the report.
  """

  alias PropertyDamage.Failure

  @doc """
  A failure name as text: a `{projection, function}` key as
  `Projection.function`, a module by its name, a check name as is, `nil` as
  an empty string.
  """
  @spec format_name(Failure.name()) :: String.t()
  def format_name({projection, function}) when is_atom(projection) and is_atom(function),
    do: "#{inspect(projection)}.#{function}"

  def format_name(nil), do: ""

  def format_name(name) when is_atom(name) do
    case Atom.to_string(name) do
      "Elixir." <> _module -> inspect(name)
      string -> string
    end
  end

  def format_name(name), do: inspect(name)

  @doc """
  Where a setup failure happened, for a reader: the setup command, its setup
  index and the cause, and for an unresolved placeholder the field.

  A setup failure implicates no root, so `FailureReport.failure_index/1` is `nil` for it;
  this names the place instead, for example
  `"setup command 1 (MyApp.Login), cause: command"` or
  `"adapter setup/1, cause: adapter_setup"`. Takes a report's
  `failure_reason`; returns `nil` for any other term.
  """
  @spec setup_location(Failure.t() | term()) :: String.t() | nil
  def setup_location(%Failure{type: %Failure.Setup{cause: :adapter_setup}}),
    do: "adapter setup/1, cause: adapter_setup"

  def setup_location(%Failure{type: %Failure.Setup{setup_index: nil} = setup}),
    do: "setup phase, cause: #{setup.cause}"

  def setup_location(%Failure{type: %Failure.Setup{cause: :unresolved_placeholder} = setup}) do
    "setup command #{setup.setup_index} (#{command_name(setup.command)}), " <>
      "cause: unresolved_placeholder, field #{inspect(setup.field)}"
  end

  def setup_location(%Failure{type: %Failure.Setup{} = setup}),
    do:
      "setup command #{setup.setup_index} (#{command_name(setup.command)}), cause: #{setup.cause}"

  def setup_location(_reason), do: nil

  @doc """
  A command module as text, or `"no command"` for `nil`.
  """
  @spec command_name(struct() | nil) :: String.t()
  def command_name(%{__struct__: module}), do: inspect(module)
  def command_name(nil), do: "no command"
end
