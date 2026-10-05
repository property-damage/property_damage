defmodule SeededDivergenceTest do
  @moduledoc """
  Non-vacuity for the oracle: prove the differential can actually catch a
  transport bug, and that it is the *oracle* doing the catching.

  The seeded bug (`seed_bug: true` on the UI adapter) makes UI label creation
  fill the wrong colour. The model never specifies a label's colour, so none of
  its own invariants fire on a single transport: only comparing the two
  transports reveals that the same intent produced different observable state.
  Without the flag the same sequences are equivalent, so the divergence is caused
  by the bug, not by flakiness.
  """

  use ExUnit.Case, async: false

  alias GiteaBench.Commands.CreateLabel
  alias PropertyDamage.{Failure, FailureReport, Sequence}

  @api_url Application.compile_env(:gitea_bench, :api_url)
  @ui_url Application.compile_env(:gitea_bench, :ui_url)
  @admin_user Application.compile_env(:gitea_bench, :admin_user)
  @admin_password Application.compile_env(:gitea_bench, :admin_password)

  defp api_opts,
    do: [base_url: @api_url, admin_user: @admin_user, admin_password: @admin_password]

  defp ui_opts(extra),
    do: [base_url: @ui_url, admin_user: @admin_user, admin_password: @admin_password] ++ extra

  defp oracle(seed, ui_extra) do
    PropertyDamage.run(
      model: GiteaBench.Model,
      targets: [
        {GiteaBench.ApiAdapter, name: "api", config: Map.new(api_opts())},
        {GiteaBench.UiAdapter, name: "ui", config: Map.new(ui_opts(ui_extra))}
      ],
      compare: :correctness,
      equivalence: :structural,
      max_commands: 12,
      max_runs: 1,
      seed: seed
    )
  end

  @tag timeout: 600_000
  test "the oracle catches the seeded colour bug and pins it to a CreateLabel" do
    # A sequence that exercises CreateLabel diverges under the bug; scan a few
    # seeds for the first one that does.
    divergent =
      Enum.find_value(1..8, fn seed ->
        case oracle(seed, seed_bug: true) do
          {:error, %FailureReport{kind: :diverged} = report} -> report
          _ -> nil
        end
      end)

    assert divergent, "expected at least one seeded sequence to diverge"

    divergence = Failure.detail(divergent.failure_reason)
    assert is_integer(divergence.root)

    assert %CreateLabel{} =
             Enum.at(Sequence.to_list(divergent.original_sequence), divergence.root)

    assert divergent.variant == %{index: 1, name: "ui"}

    {:ok, [ref_label]} = divergence.reference_result
    {:ok, [ui_label]} = divergence.divergent_result
    assert ref_label.name == ui_label.name
    refute ref_label.color == ui_label.color
  end

  @tag timeout: 600_000
  test "without the bug, the same sequences are equivalent" do
    for seed <- 1..3 do
      result = oracle(seed, [])

      assert match?({:ok, _stats}, result),
             "seed #{seed} unexpectedly diverged:\n" <> inspect(result, pretty: true)
    end
  end
end
