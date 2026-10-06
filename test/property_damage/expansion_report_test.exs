defmodule PropertyDamage.ExpansionReportTest do
  # What a reader sees of expansions: the report's `expansions` field (per
  # variant, the entry and leaf modules each root ran), the entry each variant
  # ran at the failing root, the leaf a failure happened in, persistence,
  # command telemetry, the exported script, and the per-entry counters.
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO
  import PropertyDamage.Test.VariantSupport

  alias PropertyDamage.{Export, FailureReport, Persistence}
  alias PropertyDamage.FailureReport.Formatter
  alias PropertyDamage.Progress.Printer
  alias PropertyDamage.Sequence.Position
  alias PropertyDamage.Test.ExpansionRun, as: X

  alias PropertyDamage.Test.ExpansionRun.{
    Credit,
    Noise,
    Pay,
    RecordingAdapter,
    Refund,
    SecondCreditFails,
    Totals
  }

  defp model!(name, opts), do: X.define_model!(Module.concat(ExpansionB.Report, name), opts)

  # The model `name`, defined on first use.
  defp model_once!(name, opts) do
    module = Module.concat(ExpansionB.Report, name)
    if Code.ensure_loaded?(module), do: module, else: model!(name, opts)
  end

  defp run(model, targets, extra) do
    PropertyDamage.run(
      Keyword.merge(
        [
          model: model,
          targets: targets,
          compare: [converge_within: 30],
          max_runs: 1,
          max_commands: 8,
          validate: false
        ],
        extra
      )
    )
  end

  defp seed!(model, max_commands, predicate) do
    X.find_seed(model, max_commands, 1..2_000, predicate) ||
      flunk("no seed in 1..2000 generates the roots this test needs")
  end

  # The entry a group of executed commands realized under `refund_two/2`.
  defp entry([%Noise{}]), do: nil
  defp entry([%Refund{}]), do: "Refund[0]"
  defp entry([%Credit{}, %Credit{}]), do: "Refund[1]"

  defp entry_text(%{entry: entry, leaves: leaves}),
    do: "#{entry} = [#{Enum.map_join(leaves, ", ", &X.short/1)}]"

  defp expansions(report, name), do: report |> Map.fetch!(:expansions) |> Map.fetch!(name)

  # A two-variant divergence, unshrunk: "beta" credits one too much on every
  # Credit leaf. The first seed in 1..30 that fails.
  defp diverged_report do
    model = model_once!(Diverged, expansions: [{Refund, &X.refund_two/2}])

    Enum.find_value(1..30, fn seed ->
      recorder = start_recorder()

      targets = [X.target("alpha", recorder), X.target("beta", recorder, %{bug: :credit})]

      case run(model, targets, seed: seed, shrink: false) do
        {:error, %FailureReport{} = report} -> {report, recorded(recorder)}
        {:ok, _stats} -> nil
      end
    end) || flunk("no seed in 1..30 fails: the second variant never ran a Refund rewrite")
  end

  # A one-target run whose adapter refuses the second leaf of the first Refund
  # root, unshrunk. Returns the report and that root's index.
  defp failed_leaf_report do
    model = model_once!(FailedLeaf, expansions: [{Refund, &X.refund_rewrite/2}])
    seed = seed!(model, 5, &Enum.any?(&1, fn root -> match?(%Refund{}, root) end))
    root = model |> X.roots(seed, 5) |> Enum.find_index(&match?(%Refund{}, &1))
    target = X.target("solo", nil, %{fail_part: 1})

    assert {:error, %FailureReport{} = report} =
             run(model, [target], seed: seed, max_commands: 5, shrink: false)

    {report, root}
  end

  describe "the report's expansions field" do
    test "lists, per variant, the entry and leaf modules each executed root ran" do
      {report, entries} = diverged_report()

      assert report |> Map.fetch!(:expansions) |> Map.keys() |> Enum.sort() == ["alpha", "beta"]

      for name <- ["alpha", "beta"] do
        executed = entries |> X.segments(name) |> List.last()

        expected =
          for {{_tag, commands}, index} <- Enum.with_index(X.by_root(executed)) do
            %{root: index, entry: entry(commands), leaves: X.modules(commands)}
          end

        assert expansions(report, name) == expected
      end

      assert %{entry: "Refund[1]"} =
               report |> expansions("beta") |> Enum.at(report.failed_at_index)
    end

    test "the terminal report prints beside the failing root the entry each variant ran" do
      {report, _entries} = diverged_report()
      lines = report |> Formatter.format(:terminal, color: false) |> String.split("\n")

      alpha = report |> expansions("alpha") |> Enum.at(report.failed_at_index) |> entry_text()
      beta = report |> expansions("beta") |> Enum.at(report.failed_at_index) |> entry_text()
      assert beta == "Refund[1] = [Credit, Credit]"

      assert Enum.any?(lines, &(&1 =~ "alpha" and &1 =~ alpha and &1 =~ ~r/reference/i)),
             "no line names alpha's entry #{alpha} as the reference's"

      assert Enum.any?(lines, &(&1 =~ "beta" and &1 =~ beta)),
             "no line names beta's entry #{beta}"
    end

    @tag :tmp_dir
    test "survives a persistence round trip at format version 13", %{tmp_dir: dir} do
      {report, _entries} = diverged_report()
      assert expansions(report, "beta") != []

      assert {:ok, path} = Persistence.save(report, dir)
      assert <<"PD", 13::8, _rest::binary>> = File.read!(path)
      assert {:ok, loaded} = Persistence.load(path)
      assert Map.fetch!(loaded, :expansions) == Map.fetch!(report, :expansions)
      assert Map.fetch!(loaded, :expansion_counts) == Map.fetch!(report, :expansion_counts)
    end

    @tag :tmp_dir
    test "a version 12 file is refused", %{tmp_dir: dir} do
      {report, _entries} = diverged_report()
      term_binary = :erlang.term_to_binary(%{report: report}, [:compressed])
      checksum = :erlang.crc32(term_binary)
      path = Path.join(dir, "v12-legacy.pd")
      File.write!(path, <<"PD", 12::8, checksum::32, term_binary::binary>>)

      assert {:error, {:unsupported_format_version, 12, 13}} = Persistence.load(path)
    end
  end

  describe "a failure in a leaf" do
    test "is located at its root, and the detail names the leaf within the root" do
      {report, root} = failed_leaf_report()

      assert report.failed_at_index == root
      step = FailureReport.failure_step(report)
      assert step.position == X.call(Position, :leaf, [root, 1])
      assert X.call(Position, :describe, [step.position]) == "leaf 1 of root #{root}"

      formatted = Formatter.format(report, :terminal, color: false)
      assert formatted =~ "leaf 1 of root #{root}"
    end

    test "progress printing names the leaf" do
      {report, root} = failed_leaf_report()

      printed = capture_io(fn -> Printer.print_failure(report) end)
      assert printed =~ "leaf 1 of root #{root}"
      assert printed =~ inspect(Credit)
    end
  end

  describe "command telemetry" do
    test "names the root index of every root and leaf, and the leaf index of every leaf" do
      test_pid = self()
      handler = "expansion-telemetry-#{System.unique_integer([:positive])}"

      :telemetry.attach_many(
        handler,
        [[:property_damage, :command, :start], [:property_damage, :command, :stop]],
        fn [_, _, event], _measurements, metadata, _config ->
          if metadata.variant.name == "tel" do
            send(test_pid, {
              :command,
              event,
              metadata.command,
              metadata.phase,
              Map.get(metadata, :root_index, :absent),
              Map.get(metadata, :leaf_index, :absent)
            })
          end
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      model =
        model!(Telemetry,
          expansions: [{Refund, &X.refund_rewrite/2}],
          setup: [Noise],
          teardown: [Noise]
        )

      seed =
        seed!(model, 5, fn roots ->
          Enum.any?(roots, &match?(%Refund{}, &1)) and Enum.any?(roots, &match?(%Noise{}, &1))
        end)

      target = X.target("tel", nil)
      assert {:ok, _stats} = run(model, [target], seed: seed, max_commands: 5)

      events = take_commands()
      {fixtures, roots} = Enum.split_with(events, &(elem(&1, 3) in [:setup, :teardown]))

      assert Enum.any?(fixtures, &(elem(&1, 3) == :setup))
      assert Enum.any?(fixtures, &(elem(&1, 3) == :teardown))

      for {:command, _event, _module, _phase, root_index, leaf_index} <- fixtures do
        assert {root_index, leaf_index} == {nil, nil}
      end

      expected =
        model
        |> X.roots(seed, 5)
        |> Enum.with_index()
        |> Enum.flat_map(fn
          {%Noise{}, index} -> [{Noise, index, nil}]
          {%Refund{}, index} -> [{Credit, index, 0}, {Credit, index, 1}]
        end)

      for event <- [:start, :stop] do
        assert for(
                 {:command, ^event, module, _phase, root_index, leaf_index} <- roots,
                 do: {module, root_index, leaf_index}
               ) == expected
      end
    end
  end

  defp take_commands do
    receive do
      {:command, _, _, _, _, _} = message -> [message | take_commands()]
    after
      0 -> []
    end
  end

  describe "an exported script" do
    test "runs the reference's concrete leaves and says so in its header" do
      model =
        model!(Export,
          expansions: [{Refund, &X.refund_rewrite/2}],
          checks: [Totals, SecondCreditFails]
        )

      seed = seed!(model, 6, &Enum.any?(&1, fn root -> match?(%Refund{}, root) end))
      recorder = start_recorder()

      assert {:error, %FailureReport{} = report} =
               run(model, [X.target("solo", recorder)], seed: seed, max_commands: 6)

      reproduction = recorder |> recorded() |> X.segments("solo") |> List.last()
      leaves = report |> expansions("solo") |> Enum.flat_map(& &1.leaves)
      assert leaves == Enum.map(reproduction, & &1.__struct__)
      assert Credit in leaves

      script =
        Export.to_script(report, :curl,
          base_url: "http://localhost:4000",
          adapter: RecordingAdapter
        )

      steps = for [_, name] <- Regex.scan(~r/=== Step \d+: (\w+)/, script), do: name
      assert steps == Enum.map(leaves, &X.short/1)

      [header | _] = String.split(script, "=== Step 1:", parts: 2)
      assert header =~ ~r/#[^\n]*reference/i
    end
  end

  describe "the entry counters" do
    # The entry a group realized under `refund_two/2` and `none/2`.
    defp counted([%Pay{}]), do: {Pay, :forced}

    defp counted(commands) do
      case entry(commands) do
        nil -> nil
        key -> {Refund, key}
      end
    end

    defp tally(pairs) do
      Enum.reduce(pairs, %{}, fn {root, key}, acc ->
        Map.update(acc, root, %{key => 1}, &Map.update(&1, key, 1, fn n -> n + 1 end))
      end)
    end

    test "stats count each variant's entries per root module, forced included" do
      model =
        model!(Counts,
          commands: [Noise, Refund, Pay],
          expansions: [{Refund, &X.refund_two/2}, {Pay, &X.none/2}]
        )

      recorder = start_recorder()

      assert {:ok, stats} =
               run(model, [X.target("alpha", recorder), X.target("beta", recorder)],
                 seed: 3,
                 max_runs: 3,
                 max_commands: 6
               )

      entries = recorded(recorder)

      expected =
        Map.new(["alpha", "beta"], fn name ->
          pairs =
            for segment <- X.segments(entries, name),
                {_tag, commands} <- X.by_root(segment),
                pair <- [counted(commands)],
                pair != nil,
                do: pair

          {name, tally(pairs)}
        end)

      assert Enum.any?(Map.values(expected), &((get_in(&1, [Refund, "Refund[1]"]) || 0) > 0))
      assert Enum.any?(Map.values(expected), &((get_in(&1, [Pay, :forced]) || 0) > 0))
      assert Map.fetch!(stats, :expansion_counts) == expected

      # The @compare counters keep their shape: one boundary per root.
      assert Map.keys(stats.compare_counts) == [{Totals, :totals}]
      counts = stats.compare_counts[{Totals, :totals}]
      assert counts |> Map.keys() |> Enum.sort() == [:compared_at, :waited_at, :waited_ms]
      assert counts.compared_at == 18
    end

    test "the report counts each variant's entries per root module" do
      {report, _entries} = diverged_report()
      counts = Map.fetch!(report, :expansion_counts)
      assert counts |> Map.keys() |> Enum.sort() == ["alpha", "beta"]

      for name <- ["alpha", "beta"] do
        ran =
          report
          |> expansions(name)
          |> Enum.filter(& &1.entry)
          |> Enum.map(&{Refund, &1.entry})
          |> tally()

        for {root, keys} <- ran, {key, n} <- keys do
          assert (get_in(counts, [name, root, key]) || 0) >= n
        end
      end

      assert (get_in(counts, ["beta", Refund, "Refund[1]"]) || 0) >= 1
    end
  end
end
