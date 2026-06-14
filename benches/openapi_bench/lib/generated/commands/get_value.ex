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

  # Map an HTTP response to events. `status` is the HTTP status code and
  # `response` the decoded body; return a list of event structs, typically
  # keyed on status (e.g. a 200 vs a 404). The adapter calls this for every
  # completed HTTP response, so non-2xx outcomes can become events too.
  # Example:
  #   def events(_command, 200, body), do: [%OpenapiBench.Generated.Events.ValueRetrieved{}]
  #   def events(_command, 404, _body), do: []
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
