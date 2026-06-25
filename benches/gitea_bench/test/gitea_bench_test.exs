defmodule GiteaBenchTest do
  @moduledoc """
  The headline demonstration: one transport-agnostic model, two transports, an
  oracle comparing them.

    1. The model drives the **API** transport and its invariants hold.
    2. The same model drives the **UI** (Playwright) transport and the same
       invariants hold.
    3. The **differential oracle** runs the same generated sequence against both
       transports (API as reference) and asserts they reach identical observable
       state.

  Browser automation is slow, so command/run counts are modest. Each differential
  call uses `max_runs: 1` and loops here, because `Differential.run/1` sets each
  target up only once; a fresh setup per call resets both forges, giving a clean
  comparison per generated sequence (see README).
  """

  use ExUnit.Case, async: false

  @api_url Application.compile_env(:gitea_bench, :api_url)
  @ui_url Application.compile_env(:gitea_bench, :ui_url)
  @admin_user Application.compile_env(:gitea_bench, :admin_user)
  @admin_password Application.compile_env(:gitea_bench, :admin_password)

  defp api_opts,
    do: [base_url: @api_url, admin_user: @admin_user, admin_password: @admin_password]

  defp ui_opts, do: [base_url: @ui_url, admin_user: @admin_user, admin_password: @admin_password]

  @tag timeout: 600_000
  test "the model drives the API transport with all invariants holding" do
    assert {:ok, _stats} =
             PropertyDamage.run(
               model: GiteaBench.Model,
               adapter: GiteaBench.ApiAdapter,
               adapter_config: Map.new(api_opts()),
               max_commands: 16,
               max_runs: 5
             )
  end

  @tag timeout: 600_000
  test "the same model drives the UI transport with all invariants holding" do
    assert {:ok, _stats} =
             PropertyDamage.run(
               model: GiteaBench.Model,
               adapter: GiteaBench.UiAdapter,
               adapter_config: Map.new(ui_opts()),
               max_commands: 10,
               max_runs: 2
             )
  end

  @tag timeout: 600_000
  test "oracle: API and UI transports agree on every generated sequence" do
    for seed <- 1..4 do
      assert {:ok, result} =
               PropertyDamage.Differential.run(
                 model: GiteaBench.Model,
                 targets: [
                   {GiteaBench.ApiAdapter, role: :reference, opts: api_opts()},
                   {GiteaBench.UiAdapter, name: "ui", opts: ui_opts()}
                 ],
                 compare: :correctness,
                 equivalence: :structural,
                 max_commands: 10,
                 max_runs: 1,
                 seed: seed
               )

      assert result.status == :equivalent,
             "seed #{seed} diverged:\n" <> inspect(result.divergences, pretty: true)
    end
  end
end
