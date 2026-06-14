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
