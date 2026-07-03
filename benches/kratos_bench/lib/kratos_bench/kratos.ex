defmodule KratosBench.Kratos do
  @moduledoc """
  Thin client over Ory Kratos's public (self-service) and admin APIs.

  Registration and login use the **API flow** (no browser/CSRF): fetch a flow to
  get its action URL, then submit the method payload. The admin API is used to
  list, delete, and reset identities — the ground truth the invariants check the
  model against.
  """

  @type t :: %{public_url: String.t(), admin_url: String.t()}

  @spec new(map()) :: t()
  def new(config) do
    %{
      public_url: String.trim_trailing(config.public_url, "/"),
      admin_url: String.trim_trailing(config.admin_url, "/")
    }
  end

  @doc "Block until the admin API reports ready, or raise after ~40s."
  @spec ensure_ready(t()) :: :ok
  def ensure_ready(client, attempts \\ 80) do
    case Req.get(client.admin_url <> "/admin/health/ready", retry: false) do
      {:ok, %{status: 200}} ->
        :ok

      _ when attempts > 1 ->
        Process.sleep(500)
        ensure_ready(client, attempts - 1)

      other ->
        raise "Kratos admin API never became ready: #{inspect(other)}"
    end
  end

  @doc "Delete every identity (per-sequence isolation, since DSN=memory persists)."
  @spec reset!(t()) :: :ok
  def reset!(client) do
    for %{"id" => id} <- raw_identities(client) do
      Req.delete!(client.admin_url <> "/admin/identities/#{id}", retry: false)
    end

    :ok
  end

  @doc """
  Submit a password registration through the API flow.

  Returns `{status, body}` where `status` is Kratos's HTTP status (200 on success,
  4xx when the web_hook aborted the flow). No exception on 4xx.
  """
  @spec register(t(), String.t(), String.t()) :: {non_neg_integer(), map()}
  def register(client, email, password) do
    action = flow_action(client, "/self-service/registration/api")

    resp =
      Req.post!(action,
        json: %{method: "password", traits: %{email: email}, password: password},
        headers: [{"accept", "application/json"}],
        retry: false
      )

    {resp.status, resp.body}
  end

  @doc "Attempt a password login through the API flow. Returns the HTTP status."
  @spec login(t(), String.t(), String.t()) :: non_neg_integer()
  def login(client, email, password) do
    action = flow_action(client, "/self-service/login/api")

    resp =
      Req.post!(action,
        json: %{method: "password", identifier: email, password: password},
        headers: [{"accept", "application/json"}],
        retry: false
      )

    resp.status
  end

  @doc """
  List identities as `%{email => %{role: role | nil}}` — the observable SUT state.
  """
  @spec list_identities(t()) :: %{String.t() => %{role: String.t() | nil}}
  def list_identities(client) do
    for %{"traits" => traits} <- raw_identities(client), into: %{} do
      {traits["email"], %{role: traits["role"]}}
    end
  end

  @doc "Delete the identity with the given email (no-op if absent)."
  @spec delete_identity(t(), String.t()) :: :ok
  def delete_identity(client, email) do
    case Enum.find(raw_identities(client), &(get_in(&1, ["traits", "email"]) == email)) do
      %{"id" => id} ->
        Req.delete!(client.admin_url <> "/admin/identities/#{id}", retry: false)
        :ok

      nil ->
        :ok
    end
  end

  # --- internals -------------------------------------------------------------

  defp raw_identities(client) do
    Req.get!(client.admin_url <> "/admin/identities",
      params: [per_page: 250],
      retry: false
    ).body
  end

  defp flow_action(client, path) do
    body =
      Req.get!(client.public_url <> path,
        headers: [{"accept", "application/json"}],
        retry: false
      ).body

    get_in(body, ["ui", "action"]) ||
      raise "no flow action in #{path} response: #{inspect(body)}"
  end
end
