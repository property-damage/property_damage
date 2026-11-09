defmodule PropertyDamage.FailureIdentityArtifactTest do
  # A failure's identity is its signature: `Failure.signature/2` builds the
  # `{kind, name, variant_index}` tuple the shrinker compares, and the replay
  # artifact records that one tuple instead of three loose keys. The artifact
  # reproduces when the signature, the failing target and the root all agree.
  #
  # Calls to functions the change introduces go through `apply/3`, so this
  # file compiles before the change and each test fails on its own.
  use ExUnit.Case, async: true

  alias PropertyDamage.{Failure, FailureReport, ReplayArtifact, Shrinker}
  alias PropertyDamage.Test.ExpansionFor, as: F
  alias PropertyDamage.Test.ReplayFixtures, as: R

  # At seed 2 the run fails in run 1 on the "second" target (variant index 1);
  # see replay_artifact_test.exs.
  @seed 2
  @max_commands 8

  defp failing do
    targets = [F.target("ref"), F.target("second", :random, %{bug: :credit})]

    assert {:error, %FailureReport{} = report} =
             R.run(F.Model, targets,
               seed: @seed,
               max_runs: 1,
               max_commands: @max_commands,
               replay_dir: R.tmp_dir!()
             )

    F.drain()
    report
  end

  # credo:disable-for-next-line Credo.Check.Refactor.Apply
  defp signature(reason, index), do: apply(Failure, :signature, [reason, index])

  describe "Failure.signature/2" do
    test "is the kind, name and variant index of a check failure" do
      check = Failure.from_signature(:check_failed, {PropertyDamage.Foo, :bar})
      assert signature(check, 3) == {:check_failed, {PropertyDamage.Foo, :bar}, 3}

      idempotency = Failure.from_signature(:idempotency_violation, nil)
      assert signature(idempotency, 0) == {:idempotency_violation, nil, 0}
    end

    test "is {:unknown, nil, index} for a reason that is not a failure" do
      assert signature(:some_atom, 2) == {:unknown, nil, 2}
      assert signature({:error, :boom}, 0) == {:unknown, nil, 0}
      assert signature(nil, 1) == {:unknown, nil, 1}
    end

    test "agrees with the signature of a real failing run" do
      report = failing()
      assert report.variant.index == 1

      assert signature(FailureReport.failure_reason(report), report.variant.index) ==
               {Failure.kind(FailureReport.failure_reason(report)),
                Failure.name(FailureReport.failure_reason(report)), 1}
    end

    test "lives next to from_signature, and the shrinker no longer exports it" do
      Code.ensure_loaded!(Failure)
      Code.ensure_loaded!(Shrinker)

      assert function_exported?(Failure, :from_signature, 2)
      assert function_exported?(Failure, :signature, 2)
      refute function_exported?(Shrinker, :failure_signature, 2)
    end

    test "round-trips through from_signature" do
      for {kind, name} <- [
            {:check_failed, :a_check},
            {:diverged, {PropertyDamage.Foo, :bar}},
            {:latency_exceeded, :p99}
          ] do
        failure = Failure.from_signature(kind, name)
        assert signature(failure, 0) == {kind, name, 0}
      end
    end
  end

  describe "the replay artifact at format 3" do
    test "records the signature and the root in its failure map" do
      report = failing()
      term = ReplayArtifact.build(report)

      assert term.format == 3

      assert term.failure == %{
               signature: signature(FailureReport.failure_reason(report), report.variant.index),
               root_index: report.failed_at_index
             }
    end

    @tag :tmp_dir
    test "is written, read back and reproduced by the report it came from", %{tmp_dir: dir} do
      report = failing()
      term = ReplayArtifact.build(report)
      {:ok, path} = ReplayArtifact.write(term, dir)

      assert File.read!(path)
             |> String.starts_with?("# PropertyDamage replay artifact, format 3\n")

      assert {:ok, read} = ReplayArtifact.read(path)
      assert read == term
      assert ReplayArtifact.reproduced?(read, report)
    end

    test "is not reproduced when the root, the target or the signature differs" do
      report = failing()
      term = ReplayArtifact.build(report)
      assert ReplayArtifact.reproduced?(term, report)

      {kind, name, index} = term.failure.signature

      other_root = put_in(term, [:failure, :root_index], term.failure.root_index + 1)
      other_kind = put_in(term, [:failure, :signature], {:adapter_error, name, index})
      other_name = put_in(term, [:failure, :signature], {kind, :another_check, index})
      renamed = %{report | variant: %{report.variant | name: "another target"}}

      refute ReplayArtifact.reproduced?(other_root, report)
      refute ReplayArtifact.reproduced?(other_kind, report)
      refute ReplayArtifact.reproduced?(other_name, report)
      refute ReplayArtifact.reproduced?(term, renamed)
    end

    test "is not reproduced when the signature names the other target" do
      report = failing()
      term = ReplayArtifact.build(report)
      {kind, name, index} = term.failure.signature
      other_index = rem(index + 1, length(term.targets))

      moved = put_in(term, [:failure, :signature], {kind, name, other_index})
      refute ReplayArtifact.reproduced?(moved, report)
    end

    test "a format-2 header is refused naming formats 2 and 3" do
      term = ReplayArtifact.build(failing())
      [_header, body] = String.split(ReplayArtifact.encode(term), "\n", parts: 2)
      text = "# PropertyDamage replay artifact, format 2\n" <> body

      assert {:error, message} = ReplayArtifact.parse(text)

      assert message ==
               "the replay artifact header names format 2; this version reads format 3"
    end
  end
end
