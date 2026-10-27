defmodule PropertyDamage.FailureReport.LayoutTest do
  # The terminal failure report (DR-055): five sections in a fixed order, one
  # Failure section whose values share a column, both compared sides listed,
  # every event under its step, full projection state, a banner of one width,
  # and a Reproduction section that binds the targets once.
  use ExUnit.Case, async: true

  alias PropertyDamage.{FailureReport, RunTrace}
  alias PropertyDamage.Sequence.Position
  alias PropertyDamage.Test.Compare.Settled
  alias PropertyDamage.Test.ReferenceReport, as: R
  alias PropertyDamage.Test.ReportLayout, as: L

  @kinds L.kinds()

  # A comparison failure's events name their target in `by`.
  defp by_names(lines) do
    lines |> Enum.join("\n") |> then(&Regex.scan(~r/by: "(\w+)"/, &1)) |> Enum.map(&List.last/1)
  end

  defp count(text, fragment), do: length(String.split(text, fragment)) - 1

  describe "every failure kind" do
    for kind <- @kinds do
      test "#{kind}: the sections follow DR-055's order and none of the removed ones prints" do
        # Sections in order, Projections exactly when a side has state, no removed heading or label.
        report = L.report(unquote(kind))
        facts = L.facts(report)

        for text <- [L.plain(report), L.strip_ansi(L.colored(report)), L.markdown(report)],
            do: L.assert_sections(text, facts)
      end

      test "#{kind}: a comparison lists both sides under headers, any other kind one listing" do
        # Reference and Variant headers for :diverged and :did_not_converge only.
        report = L.report(unquote(kind))
        facts = L.facts(report)

        for text <- [L.plain(report), L.markdown(report)], do: L.assert_sides(text, facts)
      end

      test "#{kind}: the Minimal Reproduction heading counts the roots" do
        # (1 root) or (N roots), N the roots of the reported sequence.
        report = L.report(unquote(kind))
        facts = L.facts(report)

        for text <- [L.plain(report), L.markdown(report)], do: L.assert_roots_heading(text, facts)
      end

      test "#{kind}: every Failure value starts at one column" do
        # Label values line up; continuation lines are indented to the value column.
        report = L.report(unquote(kind))
        L.assert_aligned(L.plain(report))
        L.assert_aligned(L.strip_ansi(L.colored(report)))
      end

      test "#{kind}: the banner has one width, with and without color, and the seed under it" do
        # Box lines share a width, the colored box matches the plain one, Seed follows.
        report = L.report(unquote(kind))
        L.assert_banner(L.plain(report), L.colored(report), L.facts(report))
      end

      test "#{kind}: Reproduction binds the targets once and the report ends with the replay call" do
        # targets = [...] once, calls say targets: targets, the last line is the replay call.
        report = L.report(unquote(kind))
        facts = L.facts(report)

        for text <- [L.plain(report), L.strip_ansi(L.colored(report))],
            do: L.assert_reproduction(text, facts)
      end
    end
  end

  describe "both sides of a comparison" do
    test "a three-target run lists the reference and the diverging third target, each with its own events" do
      # The agreeing second target is not listed; each listing's events are its own target's.
      report = L.report(:three_targets)
      assert report.variant.name == "c"
      text = L.plain(report)

      assert [{~s(Reference: target "a"), reference}, {~s(Variant: target "c"), variant}] =
               text |> L.section("Minimal Reproduction") |> L.listings()

      refute text =~ ~s(target "b")
      assert [_ | _] = by_names(reference)
      assert Enum.uniq(by_names(reference)) == ["a"]
      assert Enum.uniq(by_names(variant)) == ["c"]
    end

    test "a two-target divergence lists the reference's events and the variant's apart" do
      # The reference listing holds the reference's events, the variant listing the variant's.
      text = L.plain(L.report(:diverged))

      assert [{_, reference}, {_, variant}] =
               text |> L.section("Minimal Reproduction") |> L.listings()

      assert Enum.uniq(by_names(reference)) == ["a"]
      assert Enum.uniq(by_names(variant)) == ["b"]
    end
  end

  describe "the roots heading" do
    test "an expanded variant's heading counts the roots, not the leaves it ran" do
      # One root ran as two leaves: the heading says (1 root).
      report = L.report(:diverged_expanded)
      roots = L.facts(report).roots
      leaves = report |> FailureReport.steps() |> length()
      assert roots == 1 and leaves == 2, "control: one root, run as two leaves"

      assert L.heading(L.plain(report), "Minimal Reproduction") == "Minimal Reproduction (1 root)"
    end
  end

  describe "events under their step" do
    test "every event of a run prints under its own step, with an offset, in timestamp order" do
      # Each step's Paid and Settled sit between its line and the next step's.
      report = L.report(:unshrunk)

      assert Enum.all?(FailureReport.steps(report), &(&1.entries != [])),
             "control: every step has events"

      L.assert_events_under_steps(L.plain(report), L.event_names(report))
      refute L.plain(report) =~ "Not tied to a command"
    end

    test "a step's events print in timestamp order, and an injector event under Not tied to a command" do
      # Root 1's Settled (earlier timestamp) prints before its Paid; the injector event after the listing.
      report = L.report(:hand_built)
      text = L.plain(report)
      assert List.last(L.event_names(report)) == ["Settled", "Paid"], "control: timestamp order"
      L.assert_events_under_steps(text, L.event_names(report))
      L.assert_untied(text, "Balance")
    end
  end

  describe "Projections" do
    test "prints a ten-element list and a long string in full, each once, and the step's change as - and +" do
      # Full values, no truncation; before vs after the failing step for a check failure.
      text = L.plain(L.report(:hand_built))
      heading = L.heading(text, "Projections at ")
      assert heading, "no Projections heading"
      assert heading =~ "[1]" and heading =~ "- before" and heading =~ "+ after"
      body = L.section(text, "Projections at ")
      joined = Enum.join(body, "\n")

      for item <- L.items(), do: assert(count(joined, item) == 1, "#{item} once in:\n#{joined}")

      assert String.length(L.long_note()) > 40
      assert count(joined, L.long_note()) == 1
      refute joined =~ ~r/\d+ items/
      refute joined =~ "..."

      L.assert_unmarked_once(body, "items")
      L.assert_unmarked_once(body, "note")
      L.assert_diff(body, "n", "1", "2")
    end

    test "a divergence shows the reference's attribute as - and the variant's as +, equal ones once" do
      # Reference vs variant at the failing boundary, the same cut on both sides.
      report = L.report(:diverged)
      text = L.plain(report)
      heading = L.heading(text, "Projections at ")
      assert heading, "no Projections heading"
      assert heading =~ ~s(- reference "a") and heading =~ ~s(+ variant "b")

      reference = Map.fetch!(report.reference_state_at_failure, R.Ledger)

      variant =
        report.trace
        |> RunTrace.state_at(Position.prefix(report.failed_at_index))
        |> Map.fetch!(R.Ledger)

      assert variant.settled == reference.settled + 1, "control: the variant settled one more"

      body = L.section(text, "Projections at ")

      assert Enum.any?(body, &(&1 =~ ~r/^\S.*Ledger.*last applied:/)),
             "no Ledger line naming its last event"

      L.assert_diff(body, "settled", inspect(reference.settled), inspect(variant.settled))
      L.assert_diff(body, "by", ~s("a"), ~s("b"))
      L.assert_unmarked_once(body, "unsettled")
    end

    test "the variant side is its state at the failing boundary, not what it folded while finalizing" do
      # A settlement the variant folded after the boundary is in state_at_failure, not in the + lines.
      report = L.report(:late_fold)
      root = report.failed_at_index
      assert {report.kind, root} == {:diverged, 1}

      late = Enum.find(report.trace.event_log, &match?(%Settled{n: 0}, &1.event))
      assert late, "control: the variant's settlement of Pay 0 is in its trace"

      assert late.fold_index > L.last_fold_of_root(report.trace, root),
             "control: that settlement folded after the failing boundary"

      assert Map.has_key?(report.state_at_failure[R.Settles].settled, 0),
             "control: state_at_failure holds the late fold"

      amount =
        report.trace.plan
        |> PropertyDamage.Sequence.to_list()
        |> Enum.at(root)
        |> Map.fetch!(:amount)

      body = L.section(L.plain(report), "Projections at ")
      joined = Enum.join(body, "\n")
      plus = Enum.filter(body, &(&1 =~ ~r/^\s*\+ /))

      assert Enum.any?(plus, &(&1 =~ "1 => #{amount + 1}")),
             "the + side shows its own root-1 settlement"

      refute joined =~ "0 =>", "the late settlement of Pay 0 is shown:\n#{joined}"
    end
  end

  describe "the aligned Failure column" do
    test "a compared value printed over several lines continues at the value column" do
      # The wide Reference and Variant maps break over lines that stay in the column.
      text = L.plain(L.report(:wide_value))
      fields = L.assert_aligned(text)
      assert Enum.any?(fields, &(&1.continuation != [])), "control: a value spans several lines"

      assert text |> L.section("Failure") |> Enum.join("\n") =~
               "account-of-alice-with-a-long-identifier"
    end

    for kind <- [
          :failing_relation,
          :also_differed,
          :idempotency,
          :poll_timeout,
          :leaf_check,
          :setup_check
        ] do
      test "#{kind}: every Failure value starts at one column" do
        # The column holds for the fields of this failure too.
        L.assert_aligned(L.plain(L.report(unquote(kind))))
      end
    end
  end

  describe "Failure fields" do
    defp value(text, label), do: L.field_value(text, label)

    test "a divergence names its observation, step, both values and the wait against the bound" do
      # Failure, Observation, At, Reference, Variant, Compared; no Mismatch for a plain ==.
      report = L.report(:diverged)
      text = L.plain(report)
      divergence = report.failure_reason.type

      assert value(text, "Failure") =~ "diverged"
      assert value(text, "Observation") =~ FailureReport.format_name(divergence.key)
      assert value(text, "At") =~ ~r/^\[1\] /

      assert value(text, "Reference") =~ ~s("a") and
               value(text, "Reference") =~ inspect(divergence.reference_value)

      assert value(text, "Variant") =~ ~s("b") and
               value(text, "Variant") =~ inspect(divergence.variant_value)

      compared = value(text, "Compared")

      assert [_, bound] =
               Regex.run(~r/using .+, still differing after \d+ ms \(bound (\d+) ms\)/, compared)

      assert String.to_integer(bound) == report.compare[:converge_within]
      assert compared =~ ~r/^using ==, /
      assert L.fields_labeled(text, "Mismatch") == []
    end

    test "a failure to converge says the observation was still pending against the bound" do
      # Compared reads still pending after N ms (bound M ms).
      report = L.report(:did_not_converge)
      text = L.plain(report)
      assert value(text, "Failure") =~ "did not converge"
      compared = value(text, "Compared")

      assert [_, bound] =
               Regex.run(~r/using .+, still pending after \d+ ms \(bound (\d+) ms\)/, compared)

      assert String.to_integer(bound) == report.compare[:converge_within]
    end

    test "Mismatch prints the reason a using: relation failed with" do
      # {:fail, "text"} from the relation is the Mismatch value.
      text = L.plain(L.report(:failing_relation))
      assert value(text, "Mismatch") =~ "the totals of alice and bob disagree"
      assert value(text, "Compared") =~ "same_total"
    end

    test "every other observation that differed at the boundary prints on its own Also differed line" do
      # Two further observations, two lines, each with its name and both values.
      report = L.report(:also_differed)
      text = L.plain(report)
      others = report.failure_reason.type.other_keys
      assert length(others) == 2, "control: two further observations differed"
      also = L.fields_labeled(text, "Also differed")
      assert length(also) == 2

      for {field, other} <- Enum.zip(also, others) do
        type = other.failure.type
        assert field.value =~ FailureReport.format_name(type.key)

        assert field.value =~ inspect(type.reference_value) and
                 field.value =~ inspect(type.variant_value)
      end
    end

    test "a shrink stopped by its budget warns that the reproduction may not be minimal" do
      # The shrink line prints for :max_iterations and :max_time, not for :done.
      report = L.report(:diverged)

      minimal = fn r ->
        r |> L.plain() |> L.section("Failure") |> Enum.filter(&(&1 =~ ~r/minimal/i))
      end

      assert minimal.(report) == []
      assert [line] = minimal.(%{report | shrink_stop: :max_iterations})
      assert line =~ ~r/iteration/i
      assert [line] = minimal.(%{report | shrink_stop: :max_time})
      assert line =~ ~r/time/i
    end

    test "a latency budget names its statistic and its bound" do
      # The Failure section carries the statistic, the bound and its limit.
      report = L.report(:latency_exceeded)
      latency = report.failure_reason.type
      failure = report |> L.plain() |> L.section("Failure") |> Enum.join("\n")
      assert failure =~ ~r/latency/i
      assert failure =~ to_string(latency.statistic)
      assert failure =~ to_string(latency.bound)
      assert failure =~ to_string(latency.limit)
    end

    test "an idempotency violation shows both attempts' events" do
      # The original's and the retry's events are both in Failure.
      failure = :idempotency |> L.report() |> L.plain() |> L.section("Failure") |> Enum.join("\n")
      assert failure =~ ~r/attempt/i
      assert failure =~ ~s(by: "first") and failure =~ ~s(by: "retry")
    end

    test "a poll timeout shows the predicate that never held" do
      # The predicate's source is in Failure.
      report = L.report(:poll_timeout)
      info = FailureReport.poll_timeout_info(report)
      failure = report |> L.plain() |> L.section("Failure") |> Enum.join("\n")
      assert failure =~ info.predicate_source
    end
  end

  describe "Reproduction" do
    test "a report with a replay artifact ends with the replay call, which names targets: targets" do
      # The replay call is last and binds nothing of its own.
      report = %{
        L.report(:diverged)
        | replay_path: "property_damage_replays/Model_seed4242.replay.exs"
      }

      text = L.plain(report)
      L.assert_reproduction(text, L.facts(report))
      last = text |> L.lines() |> Enum.reject(&(String.trim(&1) == "")) |> List.last()
      assert last =~ "only: [replay: " and last =~ "targets: targets"
    end

    test "a target holding a pid prints it on the binding only, with a line naming its place" do
      # config.recorder is named under the binding; no #PID< elsewhere.
      report = L.report(:diverged_expanded)

      assert L.facts(report).opaque == ["config.recorder"],
             "control: the targets hold the recorder pid"

      L.assert_reproduction(L.plain(report), L.facts(report))
      assert count(L.plain(report), "#PID<") >= 1
    end
  end

  describe "the shape of DR-055's example" do
    test "an expanded divergence has the example's sections, labels, listings, diff and calls" do
      # Compared by shape against the Example in DR-055, not by bytes.
      report = %{
        L.report(:diverged_expanded)
        | replay_path: "property_damage_replays/LeafModel_seed1.replay.exs"
      }

      L.assert_example_shape(L.plain(report), L.facts(report))
    end
  end
end
