defmodule PropertyDamage.Export.HTTPSpec do
  @moduledoc """
  Describes an HTTP call for export purposes.

  This struct is used to map PropertyDamage commands to their HTTP representations,
  enabling the export of failure reports to standalone scripts (curl, Python, Elixir)
  that can reproduce the failure without the PropertyDamage framework.

  ## Usage

  Adapters can optionally implement `http_spec/2` to provide HTTP specifications:

      def http_spec(%CreateAccount{currency: currency}, _context) do
        %HTTPSpec{
          method: :post,
          path: "/api/accounts",
          body: %{currency: currency}
        }
      end

      def http_spec(%CreditAccount{account_ref: id, amount: amount}, _context) do
        %HTTPSpec{
          method: :post,
          path: "/api/accounts/:account_id/credit",
          path_params: %{account_id: id},
          body: %{amount: amount}
        }
      end

  ## Path Parameters

  Use `:param_name` syntax in paths, with corresponding keys in `path_params`:

      %HTTPSpec{
        path: "/api/accounts/:account_id/transactions/:tx_id",
        path_params: %{account_id: "acc_123", tx_id: "tx_456"}
      }

  This renders as: `/api/accounts/acc_123/transactions/tx_456`
  """

  @type method :: :get | :post | :put | :patch | :delete | :head | :options

  @type t :: %__MODULE__{
          method: method(),
          path: String.t(),
          body: map() | nil,
          headers: [{String.t(), String.t()}],
          path_params: map(),
          query_params: map()
        }

  defstruct [
    :method,
    :path,
    body: nil,
    headers: [],
    path_params: %{},
    query_params: %{}
  ]

  @doc """
  Creates a new HTTPSpec struct.

  ## Options

  - `:method` - HTTP method (required)
  - `:path` - URL path with optional `:param` placeholders (required)
  - `:body` - Request body as a map (optional)
  - `:headers` - Additional headers as keyword list or list of tuples (optional)
  - `:path_params` - Map of path parameter values (optional)
  - `:query_params` - Map of query string parameters (optional)
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    %__MODULE__{
      method: Keyword.fetch!(opts, :method),
      path: Keyword.fetch!(opts, :path),
      body: Keyword.get(opts, :body),
      headers: Keyword.get(opts, :headers, []),
      path_params: Keyword.get(opts, :path_params, %{}),
      query_params: Keyword.get(opts, :query_params, %{})
    }
  end

  @doc """
  Resolves path parameters in the path string.

  ## Examples

      iex> spec = %HTTPSpec{path: "/accounts/:id", path_params: %{id: "123"}}
      iex> HTTPSpec.resolve_path(spec)
      "/accounts/123"

      iex> spec = %HTTPSpec{path: "/accounts/:id/tx/:tx_id", path_params: %{id: "a", tx_id: "b"}}
      iex> HTTPSpec.resolve_path(spec)
      "/accounts/a/tx/b"
  """
  @spec resolve_path(t()) :: String.t()
  def resolve_path(%__MODULE__{path: path, path_params: params}) do
    Enum.reduce(params, path, fn {key, value}, acc ->
      String.replace(acc, ":#{key}", to_string(value))
    end)
  end

  @doc """
  Builds the full URL with resolved path and query parameters.

  ## Examples

      iex> spec = %HTTPSpec{path: "/accounts", query_params: %{page: 1, limit: 10}}
      iex> HTTPSpec.build_url(spec, "http://localhost:4000")
      "http://localhost:4000/accounts?limit=10&page=1"
  """
  @spec build_url(t(), String.t()) :: String.t()
  def build_url(%__MODULE__{} = spec, base_url) do
    path = resolve_path(spec)
    url = String.trim_trailing(base_url, "/") <> path

    case spec.query_params do
      params when map_size(params) == 0 -> url
      params -> url <> "?" <> URI.encode_query(params)
    end
  end

  @doc """
  Returns the HTTP method as an uppercase string.
  """
  @spec method_string(t()) :: String.t()
  def method_string(%__MODULE__{method: method}) do
    method |> to_string() |> String.upcase()
  end

  @doc """
  Checks if the spec has a request body.
  """
  @spec has_body?(t()) :: boolean()
  def has_body?(%__MODULE__{body: nil}), do: false
  def has_body?(%__MODULE__{body: body}) when map_size(body) == 0, do: false
  def has_body?(%__MODULE__{}), do: true
end
