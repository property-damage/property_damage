defmodule OpenapiBench.ExportAdapter do
  @moduledoc """
  The generated KV client plus an `http_spec/2` describing each command as an
  HTTP call, so a discovered failure can be exported to a standalone curl script
  (and executed) via `PropertyDamage.Export`.

  Execution is delegated verbatim to `OpenapiBench.Generated.Adapter` (the same
  code the scaffold emits), so a failure found through this adapter is a failure
  of the generated client. `http_spec/2` is the one piece `mix pd.scaffold` does
  not yet emit; it is derived here from the same OpenAPI-shaped introspection
  the generated commands already expose (`__http_method__/0`, `__http_path__/0`,
  `__path_params__/0`).
  """
  use PropertyDamage.Adapter

  alias OpenapiBench.Generated.Adapter, as: Generated
  alias PropertyDamage.Export.HTTPSpec

  @impl true
  defdelegate setup(config), to: Generated

  @impl true
  defdelegate teardown(config), to: Generated

  @impl true
  def execute(command, context, runtime), do: Generated.execute(command, context, runtime)

  @doc """
  Map a command to its HTTP call for export. Renders the OpenAPI path template
  (`/kv/{key}`) into the `HTTPSpec` `:param` form (`/kv/:key`) and splits the
  command's fields into path params vs. JSON body.
  """
  def http_spec(command, _context) do
    mod = command.__struct__
    path_params = mod.__path_params__()

    %HTTPSpec{
      method: mod.__http_method__(),
      path: to_spec_path(mod.__http_path__(), path_params),
      path_params: Map.take(Map.from_struct(command), path_params),
      body: body_fields(command, path_params)
    }
  end

  # "/kv/{key}" -> "/kv/:key" for each path param.
  defp to_spec_path(path, path_params) do
    Enum.reduce(path_params, path, fn param, acc ->
      String.replace(acc, "{#{param}}", ":#{param}")
    end)
  end

  defp body_fields(command, path_params) do
    fields =
      command
      |> Map.from_struct()
      |> Map.drop(path_params)
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()

    if fields == %{}, do: nil, else: fields
  end
end
