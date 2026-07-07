defmodule OpenapiBench.Generated.Commands.PutValue do
  @moduledoc """
  PUT /kv/{key} - Store a value under a key



  Generated from OpenAPI operationId: putValue

  Note: Preconditions and state-dependent overrides should be defined in the Model's
  commands/0 using `when:` and `with:` options. Simulate logic belongs in the Model's
  `simulate/2` callback.
  """

  use PropertyDamage.Command
  import PropertyDamage.Generator, only: [merge_overrides: 2]

  defstruct [:key, :value]

  # key: integer[0..4] (required, path)
  # value: integer[0..100] (required, body)

  @impl true
  def generator(overrides \\ %{}) do
    %{
      key: StreamData.integer(0..4),
      value: StreamData.integer(0..100)
    }
    |> merge_overrides(overrides)
    |> StreamData.fixed_map()
  end

  # Customized (scaffold next-step 2): map the 200 response to a completed event.
  def events(_command, 200, %{"key" => key, "value" => value}) do
    [%OpenapiBench.Generated.Events.PutValueCompleted{key: key, value: value}]
  end

  def events(command, status, response) do
    _ = {command, status, response}
    []
  end

  # HTTP Info (for adapter)
  def __http_method__, do: :put
  def __http_path__, do: "/kv/{key}"
  def __path_params__, do: [:key]
end
