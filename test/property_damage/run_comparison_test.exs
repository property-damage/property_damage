defmodule PropertyDamage.RunComparisonTest do
  @moduledoc "DR-035: run comparison over full traces (guard, alignment, ranking)."
  use ExUnit.Case, async: true

  alias PropertyDamage.EventLog.Entry
  alias PropertyDamage.{Failure, Mint, RunComparison, RunTrace, Sequence}
  alias PropertyDamage.RunComparison.Align
  alias PropertyDamage.Sequence.Position

  defmodule Cmd, do: defstruct([:request_id])
  defmodule CmdNested, do: defstruct([:opts])
  # Distinct event modules for LCS-by-module alignment tests.
  defmodule EA, do: defstruct([:v])
  defmodule EB, do: defstruct([:v])
  defmodule EC, do: defstruct([:v])
  defmodule EX, do: defstruct([:v])
  # An event carrying observable + echo fields.
  defmodule Result, do: defstruct([:status, :worker, :ref])
  defmodule Poll, do: defstruct([:n])

  defp plan, do: Sequence.linear([%Cmd{}])

  defp entries(events) do
    events
    |> Enum.with_index()
    |> Enum.map(fn {ev, i} ->
      %Entry{timestamp: i, command_index: 0, event: ev, source: :command}
    end)
  end

  defp trace(outcome, events, extra \\ []) do
    RunTrace.new(
      Keyword.merge(
        [plan: plan(), model: __MODULE__.Model, event_log: entries(events), outcome: outcome],
        extra
      )
    )
  end

  describe "comparability guard" do
    test "refuses traces with different plans (fingerprints differ)" do
      t1 = trace(:pass, [])

      t2 =
        RunTrace.new(plan: Sequence.linear([%Cmd{request_id: "z"}]), model: Model, outcome: :pass)

      c = RunComparison.compare([t1, t2])
      refute c.comparable?
      assert [_ | _] = c.guard_violations
      assert c.fields == []
    end

    test "refuses traces with different models" do
      t1 = trace(:pass, [], model: ModelA)
      t2 = trace(:pass, [], model: ModelB)
      refute RunComparison.compare([t1, t2]).comparable?
    end

    test "surfaces mixed failure signatures in the failing group" do
      t1 = trace({:fail, Failure.assertion_failed(:InvA, "a")}, [])
      t2 = trace({:fail, Failure.assertion_failed(:InvB, "b")}, [])
      c = RunComparison.compare([t1, t2])
      assert c.comparable?
      assert length(c.mixed_failure_signatures) == 2
    end
  end

  describe "event alignment (LCS by module)" do
    test "an inserted event yields one gap, not a cascade" do
      rows =
        Align.align_events([
          [%EA{}, %EB{}, %EC{}],
          [%EA{}, %EX{}, %EB{}, %EC{}]
        ])

      # EA, EB, EC each match across both traces; EX is a lone insertion row.
      matched = Enum.filter(rows, fn r -> r.events[0] != :absent and r.events[1] != :absent end)
      inserted = Enum.filter(rows, fn r -> r.events[0] == :absent end)

      assert Enum.map(matched, & &1.key) == [EA, EB, EC]
      assert [%{key: EX}] = inserted
    end
  end

  describe "discriminative classification + ranking" do
    test "a field stable-in-pass but different-in-fail ranks; a field varying across passes is incidental" do
      # worker varies across the two passing runs (incidental); status is stable
      # within each group but differs between pass and fail (discriminating).
      t0 = trace(:pass, [%Result{status: :ok, worker: 1}])
      t1 = trace(:pass, [%Result{status: :ok, worker: 2}])

      t2 =
        trace({:fail, Failure.assertion_failed(:Inv, "x")}, [%Result{status: :error, worker: 3}])

      c = RunComparison.compare([t0, t1, t2])

      status = find_field(c, [:status])
      worker = find_field(c, [:worker])

      assert status.classification == :discriminating
      assert worker.classification == :incidental

      ranked_paths = Enum.map(c.ranking, fn f -> elem(f.location, 4) end)
      assert [:status] in ranked_paths
      refute [:worker] in ranked_paths
    end

    test "N=2 (one pass, one fail) degrades to a pairwise diff: server-resolved diff discriminates" do
      t0 = trace(:pass, [%Result{status: :ok}])
      t1 = trace({:fail, Failure.assertion_failed(:Inv, "x")}, [%Result{status: :error}])

      c = RunComparison.compare([t0, t1])
      assert find_field(c, [:status]).classification == :discriminating
    end

    test "same-module repetition-count differences are down-ranked to incidental" do
      # One trace polls twice, the other three times: the extra Poll rows are
      # timing noise, not behavioral signal.
      t0 = trace(:pass, [%Poll{n: 1}, %Poll{n: 2}])

      t1 =
        trace({:fail, Failure.assertion_failed(:Inv, "x")}, [
          %Poll{n: 1},
          %Poll{n: 2},
          %Poll{n: 3}
        ])

      c = RunComparison.compare([t0, t1])
      poll_fields = Enum.filter(c.fields, fn f -> match?({:event, _, Poll, _, _}, f.location) end)

      # No Poll field is ranked as discriminating (they are repetition noise).
      refute Enum.any?(c.ranking, fn f -> match?({:event, _, Poll, _, _}, f.location) end)
      assert Enum.any?(poll_fields, &(&1.classification == :incidental))
    end
  end

  describe "provenance shading" do
    test "a minted-value echo in an event field is run-scoped (incidental), never suspicious" do
      marker = Mint.reify(Mint.new(:uuid), Position.prefix(0), [:request_id])
      plan = Sequence.linear([%Cmd{request_id: marker}])
      pos = %Position{section: :prefix, offset: 0}

      # Two passing runs whose SUT echoes the (distinct) minted request id back.
      t0 =
        RunTrace.new(
          plan: plan,
          model: Model,
          executed: %{pos => %Cmd{request_id: "mint-A"}},
          event_log: entries([%Result{ref: "mint-A"}]),
          outcome: :pass
        )

      t1 =
        RunTrace.new(
          plan: plan,
          model: Model,
          executed: %{pos => %Cmd{request_id: "mint-B"}},
          event_log: entries([%Result{ref: "mint-B"}]),
          outcome: {:fail, Failure.assertion_failed(:Inv, "x")}
        )

      c = RunComparison.compare([t0, t1])
      ref = find_field(c, [:ref])

      assert ref.provenance == :run_scoped
      assert ref.classification == :incidental
      refute Enum.any?(c.ranking, fn f -> elem(f.location, 4) == [:ref] end)
    end

    test "a nested minted command value is classified run-scoped at its leaf, not the container" do
      # A mint marker nested inside a map field: per-leaf comparison must
      # classify [:opts, :request_id] as run-scoped, not lump the whole [:opts]
      # container as a differing plan-generated field (a comparability violation).
      marker = Mint.reify(Mint.new(:uuid), Position.prefix(0), [:opts, :request_id])
      plan = Sequence.linear([%CmdNested{opts: %{request_id: marker, kind: :x}}])
      pos = %Position{section: :prefix, offset: 0}

      t0 =
        RunTrace.new(
          plan: plan,
          model: Model,
          executed: %{pos => %CmdNested{opts: %{request_id: "mint-A", kind: :x}}},
          outcome: :pass
        )

      t1 =
        RunTrace.new(
          plan: plan,
          model: Model,
          executed: %{pos => %CmdNested{opts: %{request_id: "mint-B", kind: :x}}},
          outcome: {:fail, Failure.assertion_failed(:Inv, "x")}
        )

      c = RunComparison.compare([t0, t1])

      req = find_field(c, [:opts, :request_id])
      assert req.provenance == :run_scoped
      assert req.classification == :incidental

      # The sibling plan-generated leaf is uniform (both :x) and never a violation.
      assert find_field(c, [:opts, :kind]).classification == :uniform
      refute Enum.any?(c.fields, &(&1.classification == :comparability_violation))
    end

    test "a differing plan-generated command field is a comparability violation" do
      # Same plan (so the guard passes), but the executed commands disagree on a
      # plan-generated field — the runs are not really executing the same plan.
      pos = %Position{section: :prefix, offset: 0}
      plan = Sequence.linear([%Cmd{request_id: :literal}])

      t0 =
        RunTrace.new(
          plan: plan,
          model: Model,
          executed: %{pos => %Cmd{request_id: :a}},
          outcome: :pass
        )

      t1 =
        RunTrace.new(
          plan: plan,
          model: Model,
          executed: %{pos => %Cmd{request_id: :b}},
          outcome: :pass
        )

      c = RunComparison.compare([t0, t1])
      assert find_field(c, [:request_id]).classification == :comparability_violation
    end
  end

  # ---- capture/1 and investigate/1 against a real model ----------------------

  defmodule DoThing do
    @behaviour PropertyDamage.Command
    defstruct [:n]
    @impl true
    def generator(_), do: StreamData.fixed_map(%{n: StreamData.integer(1..5)})
  end

  defmodule RealProj do
    @behaviour PropertyDamage.Model.Projection
    @impl true
    def init, do: %{}
    @impl true
    def apply(state, _), do: state
  end

  defmodule RealModel do
    @behaviour PropertyDamage.Model
    @behaviour PropertyDamage.Model.Simulator
    @impl true
    def commands, do: [DoThing]
    @impl true
    def command_sequence_projection, do: RealProj
    @impl true
    def simulator, do: __MODULE__
    @impl PropertyDamage.Model.Simulator
    def simulate(_c, _s), do: []
  end

  defmodule RealAdapter do
    use PropertyDamage.Adapter
    @impl true
    def setup(c), do: {:ok, c}
    @impl true
    def teardown(_), do: :ok
    @impl true
    def execute(%DoThing{}, _ctx, _rt), do: {:ok, []}
  end

  describe "RunTrace.capture/1" do
    test "captures a full unshrunk run as a :generated trace" do
      trace = RunTrace.capture(model: RealModel, adapter: RealAdapter, seed: 1, max_commands: 4)

      assert %RunTrace{plan_source: :generated, outcome: :pass} = trace
      assert is_binary(trace.plan_fingerprint)
      assert %Sequence{} = trace.plan
      assert is_integer(trace.run_nonce)
    end

    test "same seed + run_number capture the same plan (fingerprint-equal)" do
      a = RunTrace.capture(model: RealModel, adapter: RealAdapter, seed: 7)
      b = RunTrace.capture(model: RealModel, adapter: RealAdapter, seed: 7)
      assert a.plan_fingerprint == b.plan_fingerprint
    end
  end

  describe "investigate/1" do
    test "captures N same-plan traces with distinct nonces and compares them" do
      {traces, comparison} =
        RunComparison.investigate(
          runs: 3,
          capture: [model: RealModel, adapter: RealAdapter, seed: 3]
        )

      assert length(traces) == 3
      assert comparison.comparable?
      # Same plan across all captures.
      assert traces |> Enum.map(& &1.plan_fingerprint) |> Enum.uniq() |> length() == 1
      # Distinct recorded nonces (collision-free on a shared SUT).
      assert traces |> Enum.map(& &1.run_nonce) |> Enum.uniq() |> length() == 3
    end
  end

  defp find_field(comparison, path) do
    Enum.find(comparison.fields, fn f ->
      case f.location do
        {:command, _, ^path} -> true
        {:event, _, _, _, ^path} -> true
        _ -> false
      end
    end)
  end
end
