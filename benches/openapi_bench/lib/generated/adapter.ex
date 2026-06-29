defmodule OpenapiBench.Generated.Adapter do
  @moduledoc """
  HTTP adapter for KV Register API.

  Generated from OpenAPI spec version 1.0.0.

  ## Configuration

  Pass configuration via `adapter_config`:

      PropertyDamage.run(
        model: OpenapiBench.Generated.Model,
        adapter: OpenapiBench.Generated.Adapter,
        adapter_config: %{
          base_url: "http://localhost:4010",
          # No authentication configured
        }
      )
  """

  use PropertyDamage.Adapter

  # Req is optional: the adapter prefers it when present and falls back to
  # :httpc. Suppress the undefined-module warning so the generated code
  # compiles cleanly under --warnings-as-errors without Req as a dependency.
  @compile {:no_warn_undefined, [Req]}

  alias OpenapiBench.Generated.Commands

  @impl true
  def setup(config) do
    base_url = Map.get(config, :base_url, "http://localhost:4010")
    {:ok, Map.put(config, :base_url, base_url)}
  end

  @impl true
  def teardown(_config), do: :ok

  @impl true
  def execute(%Commands.GetValue{} = cmd, ctx, _runtime) do
    url = build_url(ctx.base_url, cmd.__struct__.__http_path__(), cmd)
    query = build_query(cmd)
    full_url = if query != "", do: url <> "?" <> query, else: url
    body = build_body(cmd)
    headers = []

    # PropertyDamage expects {:ok, [event structs]}. Map every completed HTTP
    # response (any status) to events via the command's events/3; reserve
    # {:error, _} for transport failures so a 404/409 can be an observation.
    case http_request(:get, full_url, body, headers) do
      {:ok, status, response} -> {:ok, cmd.__struct__.events(cmd, status, response)}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def execute(%Commands.PutValue{} = cmd, ctx, _runtime) do
    url = build_url(ctx.base_url, cmd.__struct__.__http_path__(), cmd)
    query = build_query(cmd)
    full_url = if query != "", do: url <> "?" <> query, else: url
    body = build_body(cmd)
    headers = []

    # PropertyDamage expects {:ok, [event structs]}. Map every completed HTTP
    # response (any status) to events via the command's events/3; reserve
    # {:error, _} for transport failures so a 404/409 can be an observation.
    case http_request(:put, full_url, body, headers) do
      {:ok, status, response} -> {:ok, cmd.__struct__.events(cmd, status, response)}
      {:error, reason} -> {:error, reason}
    end
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp build_url(base_url, path, cmd) do
    # Replace path parameters
    path =
      if function_exported?(cmd.__struct__, :__path_params__, 0) do
        Enum.reduce(cmd.__struct__.__path_params__(), path, fn param, acc ->
          value = Map.get(cmd, param)
          String.replace(acc, "{" <> to_string(param) <> "}", to_string(value))
        end)
      else
        path
      end

    base_url <> path
  end

  defp build_query(cmd) do
    if function_exported?(cmd.__struct__, :__query_params__, 0) do
      cmd.__struct__.__query_params__()
      |> Enum.map(fn param -> {param, Map.get(cmd, param)} end)
      |> Enum.reject(fn {_, v} -> is_nil(v) end)
      |> URI.encode_query()
    else
      ""
    end
  end

  defp build_body(cmd) do
    # Get body fields (exclude path and query params)
    path_params =
      if function_exported?(cmd.__struct__, :__path_params__, 0),
        do: cmd.__struct__.__path_params__(),
        else: []

    query_params =
      if function_exported?(cmd.__struct__, :__query_params__, 0),
        do: cmd.__struct__.__query_params__(),
        else: []

    excluded = MapSet.new(path_params ++ query_params)

    cmd
    |> Map.from_struct()
    |> Enum.reject(fn {k, _} -> MapSet.member?(excluded, k) end)
    |> Enum.reject(fn {_, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp http_request(method, url, body, headers) do
    # Using Req if available, otherwise fall back to :httpc
    if Code.ensure_loaded?(Req) do
      req_request(method, url, body, headers)
    else
      httpc_request(method, url, body, headers)
    end
  end

  defp req_request(method, url, body, headers) do
    opts =
      [method: method, url: url, headers: headers]
      |> maybe_add_body(method, body)

    case Req.request(opts) do
      {:ok, %{status: status, body: resp_body}} ->
        {:ok, status, resp_body}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_add_body(opts, method, body) when method in [:post, :put, :patch] and body != %{} do
    Keyword.put(opts, :json, body)
  end

  defp maybe_add_body(opts, _, _), do: opts

  defp httpc_request(method, url, body, headers) do
    Application.ensure_all_started(:inets)
    Application.ensure_all_started(:ssl)

    headers = Enum.map(headers, fn {k, v} -> {to_charlist(k), to_charlist(v)} end)

    request =
      case method do
        :get ->
          {to_charlist(url), headers}

        _ ->
          body_str = if body == %{}, do: "", else: Jason.encode!(body)
          {to_charlist(url), headers, ~c"application/json", body_str}
      end

    case :httpc.request(method, request, [], body_format: :binary) do
      {:ok, {{_, status, _}, _, resp_body}} ->
        {:ok, status, decode_body(resp_body)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp decode_body(""), do: nil

  defp decode_body(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decoded
      {:error, _} -> body
    end
  end
end
