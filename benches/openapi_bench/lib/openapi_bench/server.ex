defmodule OpenapiBench.Server do
  @moduledoc """
  Boots the in-process SUT: the `OpenapiBench.Store` Agent and a Bandit server
  running `OpenapiBench.Api`.

  `ensure_started/0` is idempotent and is called from `test_helper.exs`. When
  `PD_OPENAPI_URL` is configured the bench points at that external endpoint and
  starts nothing locally (CI service container / BYO server).
  """

  alias OpenapiBench.{Api, Store}

  @doc "Start the Store + Bandit server unless an external URL is configured."
  def ensure_started do
    if external_url() do
      :ok
    else
      start_child(Store, %{})
      start_child({Bandit, plug: Api, port: port()}, nil)
      :ok
    end
  end

  @doc "Base URL the generated adapter and tests should hit."
  def base_url, do: Application.fetch_env!(:openapi_bench, :base_url)

  @doc """
  Reset the SUT to empty and set its seeded-bug flags, for per-sequence
  isolation. `bug` seeds the dropped-write bug; `idempotency_bug` seeds the
  ignored-Idempotency-Key double-create bug. In-process this pokes the Agent
  directly; against an external URL it calls the `POST /__reset__` admin
  endpoint over HTTP.
  """
  def reset(bug, idempotency_bug \\ false) do
    if url = external_url() do
      Application.ensure_all_started(:inets)
      body = Jason.encode!(%{bug: bug, idempotency_bug: idempotency_bug})
      headers = [{~c"content-type", ~c"application/json"}]
      target = String.to_charlist(url <> "/__reset__")
      {:ok, _} = :httpc.request(:post, {target, headers, ~c"application/json", body}, [], [])
      :ok
    else
      OpenapiBench.Store.reset(bug, idempotency_bug)
    end
  end

  defp external_url, do: Application.get_env(:openapi_bench, :external_url)
  defp port, do: Application.fetch_env!(:openapi_bench, :port)

  defp start_child(Store, _) do
    case Store.start_link([]) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end

  defp start_child(child_spec, _) do
    case Supervisor.start_child(supervisor(), child_spec) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end

  defp supervisor do
    case Supervisor.start_link([], strategy: :one_for_one, name: __MODULE__.Sup) do
      {:ok, pid} -> pid
      {:error, {:already_started, pid}} -> pid
    end
  end
end
