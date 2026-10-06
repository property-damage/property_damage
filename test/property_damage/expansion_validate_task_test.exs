defmodule PropertyDamage.ExpansionValidateTaskTest do
  # `mix pd.validate --seeds N` samples N root sequences, draws the expansions
  # of every target on them and reports what the sample realized: the leaf
  # modules, every entry key with its realization count (summed over the
  # targets), the entries never realized and the roots forced to identity in
  # every sampled state. `--seed S` samples seeds S, S+1, ...; without it the
  # task prints the seeds it used.
  #
  # Not async: the task runs the compile task and prints to stdout.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Pd.Validate
  alias PropertyDamage.Test.ExpansionRun, as: X
  alias PropertyDamage.Test.ExpansionRun.RecordingAdapter

  @adapter inspect(RecordingAdapter)

  # An entry key, its leaves and the first integer after them on the line.
  @count_line ~r/(\w+)\[(\d+)\] = \[([^\]]*)\][^\d\n]*(\d+)/

  setup_all do
    model = inspect(X.define_sampling_model!(ExpansionB.ValidateTask.SamplingModel))
    {status, output} = exec([model, @adapter, "--seed", "100", "--seeds", "20"])
    {:ok, model: model, status: status, output: output}
  end

  defp exec(args) do
    ref = make_ref()
    output = capture_io(fn -> send(self(), {ref, Validate.exec(args)}) end)
    assert_received {^ref, status}
    {status, output}
  end

  defp lines(output), do: String.split(output, "\n")

  # `%{"Root[i]" => {leaves, count}}` from the count lines. Each key is printed
  # once: the count is summed over the targets.
  defp counts(output) do
    pairs =
      for line <- lines(output),
          not (line =~ "not realized"),
          [_, root, index, leaves, count] <- [Regex.run(@count_line, line)] do
        {"#{root}[#{index}]", {leaves, String.to_integer(count)}}
      end

    keys = Enum.map(pairs, &elem(&1, 0))
    assert keys == Enum.uniq(keys), "an entry key was printed twice:\n#{output}"
    Map.new(pairs)
  end

  defp realized(counts),
    do: for({key, {_leaves, n}} <- counts, n > 0, into: MapSet.new(), do: key)

  defp total(counts, root) do
    for {key, {_leaves, n}} <- counts, String.starts_with?(key, root <> "["), reduce: 0 do
      acc -> acc + n
    end
  end

  defp seeds_line(output) do
    case Regex.run(~r/^\s*Seeds: (.*)$/m, output) do
      [_, seeds] ->
        seeds
        |> then(&Regex.scan(~r/-?\d+/, &1))
        |> List.flatten()
        |> Enum.map(&String.to_integer/1)

      nil ->
        flunk("no `Seeds:` line in:\n#{output}")
    end
  end

  describe "--seeds N with --seed S" do
    test "prints every entry key realized with its count, and exits 0", ctx do
      assert ctx.status == :ok
      counts = counts(ctx.output)

      assert realized(counts) == MapSet.new(["Pay[0]", "Pay[1]", "Refund[0]", "Refund[1]"])
      assert elem(counts["Pay[0]"], 0) == "Pay"
      assert elem(counts["Pay[1]"], 0) == "Authorize, Capture"
      assert elem(counts["Refund[0]"], 0) == "Refund"
      assert elem(counts["Refund[1]"], 0) == "Credit, Credit"

      # One Pay and one Refund root per sampled sequence, one target.
      assert total(counts, "Pay") == 20
      assert total(counts, "Refund") == 20
    end

    test "lists the entries never realized", ctx do
      assert ctx.output =~ ~r/Refund\[2\][^\n]*not realized in 20 seeds/
    end

    test "lists the leaf modules realized", ctx do
      assert [_before, leaves] = String.split(ctx.output, ~r/leaf modules/i, parts: 2)
      assert leaves =~ "Authorize"
      assert leaves =~ "Capture"
      assert leaves =~ "Credit"
    end

    test "lists a root forced to identity in every sampled state", ctx do
      assert Enum.any?(lines(ctx.output), &(&1 =~ "Void" and &1 =~ ~r/forced/i))
    end

    test "prints the seeds it sampled", ctx do
      assert seeds_line(ctx.output) == Enum.to_list(100..119)
    end
  end

  describe "--seed S --seeds 1" do
    test "reports an entry the single sampled sequence could not realize", %{model: model} do
      {status, output} = exec([model, @adapter, "--seed", "5", "--seeds", "1"])

      assert status == :ok
      assert output =~ ~r/Refund\[2\][^\n]*not realized in 1 seeds?/
      assert total(counts(output), "Pay") == 1
      assert seeds_line(output) == [5]
    end
  end

  describe "--seeds N without --seed" do
    test "prints the N seeds it used", %{model: model} do
      {status, output} = exec([model, @adapter, "--seeds", "3"])

      assert status == :ok
      assert length(seeds_line(output)) == 3
      assert total(counts(output), "Pay") == 3
    end
  end

  describe "the targets drawn for" do
    test "--targets draws for each listed target", %{model: model} do
      targets =
        ~s|[{#{@adapter}, name: "a", config: %{name: "a"}}, | <>
          ~s|{#{@adapter}, name: "b", config: %{name: "b"}}]|

      {status, output} = exec([model, "--targets", targets, "--seed", "100", "--seeds", "20"])

      assert status == :ok
      counts = counts(output)
      assert total(counts, "Pay") == 40
      assert total(counts, "Refund") == 40
    end

    test "without --targets, one variant named after the adapter argument", %{model: model} do
      {positional_status, positional} = exec([model, @adapter, "--seed", "100", "--seeds", "20"])

      {listed_status, listed} =
        exec([model, "--targets", "[#{@adapter}]", "--seed", "100", "--seeds", "20"])

      assert positional_status == :ok
      assert listed_status == :ok
      assert total(counts(positional), "Pay") == 20
      assert counts(positional) == counts(listed)
    end
  end

  describe "--strict" do
    test "still turns warnings into a non-zero exit", %{model: model} do
      {status, output} = exec([model, @adapter, "--seed", "100", "--seeds", "5", "--strict"])

      assert status == :error
      assert output =~ "warning(s) in strict mode"
      assert total(counts(output), "Pay") == 5
    end
  end
end
