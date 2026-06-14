defmodule OpenapiBench.Generated.Commands.GetValue do
  @moduledoc """
  GET /kv/{key} - Read the value stored under a key



  Generated from OpenAPI operationId: getValue

  Note: Preconditions and state-dependent overrides should be defined in the Model's
  commands/0 using `when:` and `with:` options. Simulate logic belongs in the Model's
  `simulate/2` callback.
  """

  @behaviour PropertyDamage.Command
  import PropertyDamage.Generator, only: [merge_overrides: 2]

  defstruct [:key]

  # key: integer[0..4] (required, path)

  @impl true
  def generator(overrides \\ %{}) do
    %{
      key: StreamData.integer(0..4)
    }
    |> merge_overrides(overrides)
    |> StreamData.fixed_map()
  end

  # Customized (scaffold next-step 2): map a read to a ValueRetrieved event. A
  # 404 is a legitimate observation ("no value under that key") and becomes a
  # read of :unset, keyed off the command so the model can check consistency.
  def events(_command, 200, %{"key" => key, "value" => value}) do
    [%OpenapiBench.Generated.Events.ValueRetrieved{key: key, value: value}]
  end

  def events(command, 404, _response) do
    [%OpenapiBench.Generated.Events.ValueRetrieved{key: command.key, value: :unset}]
  end

  def events(command, status, response) do
    _ = {command, status, response}
    []
  end

  @impl true
  def read_only?, do: true

  # HTTP Info (for adapter)
  def __http_method__, do: :get
  def __http_path__, do: "/kv/{key}"
  def __path_params__, do: [:key]
end
