defmodule PropertyDamage.OtherFailuresReportTest do
  # A report whose run failed in several targets prints and exports the other
  # failures beside the reported one.
  use ExUnit.Case, async: true

  alias PropertyDamage.FailureReport.Formatter
  alias PropertyDamage.Persistence
  alias PropertyDamage.Test.{ActiveSet, VariantSupport}

  defmodule Same do
    @moduledoc false
    use PropertyDamage.Model.Projection

    @impl true
    def init, do: %{}

    @impl true
    def apply(state, _event), do: state

    @compare every: 1
    def same(_state, _root), do: :same
  end

  setup_all do
    {:ok, model: ActiveSet.define_model!(Module.concat(__MODULE__, Model), [Same])}
  end

  # "c" fails at root 2 (the reported failure), then "b" at root 4.
  defp report(model) do
    recorder = VariantSupport.start_recorder()

    targets = [
      ActiveSet.target("a", recorder),
      ActiveSet.target("b", recorder, %{fail: %{4 => :error}}),
      ActiveSet.target("c", recorder, %{fail: %{2 => :error}})
    ]

    assert {:error, report} =
             PropertyDamage.run(
               model: model,
               targets: targets,
               max_runs: 1,
               max_commands: 5,
               seed: 4_242,
               validate: false,
               shrink: false
             )

    report
  end

  test "terminal and markdown output list each other failure with its target and root", ctx do
    report = report(ctx.model)

    for format <- [:terminal, :markdown] do
      text = Formatter.format(report, format, color: false)
      assert text =~ "Other Failures In This Run"
      assert text =~ ~s[adapter_error in target "b" (index 1) at root 4]
      refute text =~ ~s[in target "c" (index 2) at root 2]
    end
  end

  test "both JSON forms carry the other failures", ctx do
    report = report(ctx.model)

    formatted = report |> Formatter.format(:json) |> Jason.decode!()

    assert [
             %{
               "variant" => %{"index" => 1, "name" => "b"},
               "root" => 4,
               "type" => "adapter_error"
             }
           ] =
             formatted["other_failures"]

    exported = report |> Persistence.export_json() |> Jason.decode!()

    assert [%{"variant" => %{"index" => 1, "name" => "b"}, "root" => 4} = entry] =
             exported["other_failures"]

    assert entry["failure_type"] == "adapter_error"
    assert is_binary(entry["message"])
  end
end
