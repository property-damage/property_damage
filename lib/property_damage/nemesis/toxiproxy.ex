defmodule PropertyDamage.Nemesis.Toxiproxy do
  @moduledoc """
  Shared Toxiproxy integration for the built-in network nemeses
  (`NetworkLatency`, `NetworkPartition`, `PacketLoss`).

  This module owns everything the three network nemeses share: discovering the
  Toxiproxy control-API config, deciding between a real and a simulated
  injection, and (when real) driving the control API over HTTP. The nemeses keep
  only what actually differs between them: their generator, the *pure* list of
  toxic maps they inject (`toxics/1`), and the events they emit.

  ## Config discovery (DR-038)

  The Toxiproxy config (`%{proxy_name: ..., api_url: ...}`) is discovered from
  the nemesis execution context in this order:

  1. `context[:toxiproxy]` — a top-level key. Honored so a direct `inject/2`
     call (tests, the redis bench audit) can pass config without an adapter.
  2. `context.adapter_context[:toxiproxy]` — the adapter's `setup/1` return. This
     is the path the execution engine uses: the executor builds the nemesis
     context with `:adapter_context` (never a top-level `:toxiproxy`), so an
     adapter that returns `toxiproxy: %{...}` from `setup/1` is what makes live
     injection reachable through `PropertyDamage.run`.

  When neither is present the injection is **simulated**: no HTTP call happens and
  the caller tags its event `simulated: true` so a no-op fault can never
  masquerade as a real one (see `PropertyDamage.Nemesis.simulated_event?/1`).

  ## Live vs simulated

  `inject_toxics/2` and `restore_toxics/2` return `{result, simulated?}` where
  `result` is `:ok | {:error, reason}` and `simulated?` is `true` when no config
  was found (nothing was sent to the SUT). The nemesis threads `simulated?` into
  its event.
  """

  @default_api_url "http://localhost:8474"
  @default_proxy_name "default"

  @typedoc "Toxiproxy control-API config as discovered from the context."
  @type config :: %{optional(:proxy_name) => String.t(), optional(:api_url) => String.t()}

  @typedoc "A single Toxiproxy toxic as a JSON-encodable map."
  @type toxic :: %{String.t() => term()}

  @doc """
  Discover the Toxiproxy config from a nemesis execution context.

  Returns `{:ok, config}` if a config map is found at `context[:toxiproxy]` or
  `context.adapter_context[:toxiproxy]` (top-level wins), or `:not_configured`.
  """
  @spec discover(map()) :: {:ok, config()} | :not_configured
  def discover(context) when is_map(context) do
    top = Map.get(context, :toxiproxy)

    nested =
      case Map.get(context, :adapter_context) do
        ac when is_map(ac) -> Map.get(ac, :toxiproxy)
        _ -> nil
      end

    cond do
      is_map(top) -> {:ok, top}
      is_map(nested) -> {:ok, nested}
      true -> :not_configured
    end
  end

  def discover(_context), do: :not_configured

  @doc """
  Inject the given `toxics` (a list of toxic maps) via the Toxiproxy control API.

  Returns `{result, simulated?}`:

    * `{:ok, false}` — every toxic was POSTed successfully against a discovered config.
    * `{{:error, reason}, false}` — a POST failed against a discovered config.
    * `{:ok, true}` — no config was found; nothing was sent (simulated).
  """
  @spec inject_toxics(map(), [toxic()]) :: {:ok | {:error, term()}, boolean()}
  def inject_toxics(context, toxics) do
    case discover(context) do
      {:ok, config} ->
        ensure_httpc()
        {apply_toxics(config, toxics), false}

      :not_configured ->
        {:ok, true}
    end
  end

  @doc """
  Remove the named toxics via the Toxiproxy control API.

  `names` is the list of toxic names created by `inject_toxics/2` (derive it from
  the same `toxics/1` the nemesis used to inject, so a two-toxic `:full`
  partition issues two deletes). A missing toxic (404) is treated as already
  restored. Returns `{result, simulated?}` with the same shape as
  `inject_toxics/2`.
  """
  @spec restore_toxics(map(), [String.t()]) :: {:ok | {:error, term()}, boolean()}
  def restore_toxics(context, names) do
    case discover(context) do
      {:ok, config} ->
        ensure_httpc()
        {remove_toxics(config, names), false}

      :not_configured ->
        {:ok, true}
    end
  end

  # ============================================================================
  # Control-API driving
  # ============================================================================

  defp apply_toxics(config, toxics) do
    url = toxics_url(config)

    Enum.reduce_while(toxics, :ok, fn toxic, :ok ->
      case http_post(url, toxic) do
        {:ok, _} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:toxiproxy_error, reason}}}
      end
    end)
  end

  defp remove_toxics(config, names) do
    Enum.reduce_while(names, :ok, fn name, :ok ->
      case http_delete(toxic_url(config, name)) do
        {:ok, _} -> {:cont, :ok}
        {:error, :not_found} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:toxiproxy_error, reason}}}
      end
    end)
  end

  defp toxics_url(config) do
    proxy_name = config[:proxy_name] || @default_proxy_name
    api_url = config[:api_url] || @default_api_url
    "#{api_url}/proxies/#{proxy_name}/toxics"
  end

  defp toxic_url(config, name), do: toxics_url(config) <> "/#{name}"

  # ============================================================================
  # HTTP (Toxiproxy control API over :httpc / inets)
  # ============================================================================

  # Live injection needs the inets application (which provides :httpc) running.
  # A host app that configures a nemesis via its adapter shouldn't also have to
  # remember to start it, so we start it on demand. Idempotent and only ever
  # reached on the live path (a discovered config). :ssl is started too because
  # httpc eagerly computes SSL verify defaults (via :public_key) when building
  # its request options, even for a plain-HTTP request.
  defp ensure_httpc do
    _ = Application.ensure_all_started(:inets)
    _ = Application.ensure_all_started(:ssl)
    :ok
  end

  defp http_post(url, body) do
    uri = String.to_charlist(url)
    json_body = Jason.encode!(body)

    case :httpc.request(
           :post,
           {uri, [], ~c"application/json", json_body},
           [{:timeout, 5000}],
           []
         ) do
      {:ok, {{_, status, _}, _, _}} when status in 200..299 -> {:ok, :created}
      {:ok, {{_, status, _}, _, _}} -> {:error, {:http_error, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp http_delete(url) do
    uri = String.to_charlist(url)

    case :httpc.request(:delete, {uri, []}, [{:timeout, 5000}], []) do
      {:ok, {{_, status, _}, _, _}} when status in 200..299 -> {:ok, :deleted}
      {:ok, {{_, 404, _}, _, _}} -> {:error, :not_found}
      {:ok, {{_, status, _}, _, _}} -> {:error, {:http_error, status}}
      {:error, reason} -> {:error, reason}
    end
  end
end
