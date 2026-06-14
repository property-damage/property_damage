defmodule OpenapiBench.Api do
  @moduledoc """
  A tiny real HTTP CRUD API: an integer-keyed value register.

  This is the System Under Test for the 6e OpenAPI/REST scaffold bench. It is a
  faithful register unless `OpenapiBench.Store`'s `bug` flag is set (see that
  module). The shape of every endpoint matches `spec/openapi.json`, the document
  `mix pd.scaffold` consumes to generate the test suite.

      PUT  /kv/:key   {"value": int}  -> 200 {"key": int, "value": int}
      GET  /kv/:key                   -> 200 {"key": int, "value": int} | 404
      POST /__reset__ {"bug": bool}   -> 200 {"ok": true}   (test harness only)

  `/__reset__` is intentionally NOT in the OpenAPI spec: it is harness
  infrastructure (per-sequence isolation + bug seeding), not part of the public
  contract the generated client drives.
  """
  use Plug.Router

  alias OpenapiBench.Store

  plug(Plug.Parsers, parsers: [:json], json_decoder: Jason)
  plug(:match)
  plug(:dispatch)

  put "/kv/:key" do
    with {:ok, key} <- parse_key(key),
         {:ok, value} <- fetch_value(conn.body_params) do
      stored = Store.put(key, value)
      send_json(conn, 200, %{key: key, value: stored})
    else
      :bad_key -> send_json(conn, 400, %{error: "invalid_key"})
      :bad_value -> send_json(conn, 422, %{error: "invalid_value"})
    end
  end

  get "/kv/:key" do
    case parse_key(key) do
      {:ok, key} ->
        case Store.get(key) do
          {:ok, value} -> send_json(conn, 200, %{key: key, value: value})
          :error -> send_json(conn, 404, %{error: "not_found"})
        end

      :bad_key ->
        send_json(conn, 400, %{error: "invalid_key"})
    end
  end

  post "/__reset__" do
    bug = conn.body_params |> Map.get("bug", false) |> truthy?()
    Store.reset(bug)
    send_json(conn, 200, %{ok: true})
  end

  match _ do
    send_json(conn, 404, %{error: "not_found"})
  end

  defp parse_key(key) when is_binary(key) do
    case Integer.parse(key) do
      {int, ""} -> {:ok, int}
      _ -> :bad_key
    end
  end

  defp fetch_value(%{"value" => value}) when is_integer(value), do: {:ok, value}
  defp fetch_value(_), do: :bad_value

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?(_), do: false

  defp send_json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
