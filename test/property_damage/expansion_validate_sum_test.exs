defmodule PropertyDamage.ExpansionValidateSumTest do
  # `mix pd.validate --seeds` sums each entry's realization count over the
  # targets that pick expansions (`expansion: :random`) and says so, naming
  # them. A `:reference` target copies what the first target picked and is not
  # counted again. When no target picks, the task says so in one line instead
  # of printing no entry at all.
  #
  # Not async: the task runs the compile task and prints to stdout.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Pd.Validate
  alias PropertyDamage.Test.ExpansionRun, as: X
  alias PropertyDamage.Test.ExpansionRun.RecordingAdapter

  @adapter inspect(RecordingAdapter)
  @count_line ~r/^\s+(\w+)\[(\d+)\] = \[[^\]]*\]\s+realized (\d+)$/m

  setup_all do
    {:ok, model: inspect(X.define_sampling_model!(ExpansionValidateSum.SamplingModel))}
  end

  defp exec(model, targets) do
    ref = make_ref()

    output =
      capture_io(fn ->
        send(
          self(),
          {ref, Validate.exec([model, "--targets", targets, "--seed", "100", "--seeds", "20"])}
        )
      end)

    assert_received {^ref, status}
    assert status == :ok, output
    output
  end

  defp entry(name, opts), do: "{#{@adapter}, name: #{inspect(name)}#{opts}}"

  # The realization count printed for each entry of `root`, summed.
  defp total(output, root) do
    for [_, ^root, _index, n] <- Regex.scan(@count_line, output), reduce: 0 do
      acc -> acc + String.to_integer(n)
    end
  end

  test "a :reference target is not counted again, and the line names the targets that pick",
       ctx do
    one = exec(ctx.model, "[#{entry("a", "")}, #{entry("b", ", expansion: :reference")}]")

    # One Pay and one Refund root per sampled sequence, one target picking.
    assert total(one, "Pay") == 20
    assert total(one, "Refund") == 20
    assert one =~ ~s(Counts are summed over 1 target that picks expansions: "a"\n)

    two =
      exec(
        ctx.model,
        "[#{entry("a", "")}, #{entry("b", ", expansion: :reference")}, #{entry("c", "")}]"
      )

    assert total(two, "Pay") == 40
    assert two =~ ~s(Counts are summed over 2 targets that pick expansions: "a", "c"\n)
  end

  test "with no target that picks, one line says so and no entry line is printed", ctx do
    for targets <- [
          "[#{entry("a", ", expansion: :identity")}]",
          "[#{entry("a", ", expansion: :identity")}, #{entry("b", ", expansion: :reference")}]"
        ] do
      output = exec(ctx.model, targets)
      assert output =~ "No target picks expansions"
      assert Regex.scan(~r/^\s+\w+\[\d+\] = /m, output) == []
      refute output =~ "Counts are summed"
    end
  end
end
