defmodule KratosBench do
  @moduledoc """
  Bench for `PropertyDamage.MockServiceAdapter` / `MockServiceRegistry`: the SUT is
  Ory Kratos, and PropertyDamage's mock plays the third party Kratos calls during
  registration (a blocking `web_hook` with `response.parse: true`). The mock's
  answer genuinely steers Kratos state — accept, reject (no identity persisted), or
  rewrite the identity's traits — which is what a fire-and-forget webhook cannot
  demonstrate. See `README.md`.
  """

  @mock_role "mock-assigned"

  @doc "The role trait the mock injects on a modify-registration."
  @spec mock_role() :: String.t()
  def mock_role, do: @mock_role

  @doc "The email for the n-th registration in a sequence (unique, client-chosen)."
  @spec email_for(non_neg_integer()) :: String.t()
  def email_for(n), do: "user-#{n}@kratos.pd.local"

  @doc "Adapter config from application env, plus any overrides (e.g. seeded bugs)."
  @spec adapter_config(keyword() | map()) :: map()
  def adapter_config(overrides \\ %{}) do
    %{
      public_url: Application.fetch_env!(:kratos_bench, :public_url),
      admin_url: Application.fetch_env!(:kratos_bench, :admin_url),
      password: Application.fetch_env!(:kratos_bench, :password),
      mock_listen_port: Application.fetch_env!(:kratos_bench, :mock_listen_port)
    }
    |> Map.merge(Map.new(overrides))
  end
end
