defmodule PropertyDamage.ExpansionDocReplayTest do
  # A replay artifact does not record the doc of an entry: replaying a failure
  # reads each doc from the model, as a run does, so the replayed report
  # carries the docs of the original.
  use ExUnit.Case, async: true

  import PropertyDamage.Test.VariantSupport, only: [start_recorder: 0]

  alias PropertyDamage.FailureReport
  alias PropertyDamage.Test.Expansion, as: X
  alias PropertyDamage.Test.Expansion.{Authorize, Capture, Pay}
  alias PropertyDamage.Test.ReplayFixtures, as: R

  @as_is "the payment as it is"
  @two_steps "authorize, then capture"

  defp documented(%Pay{amount: a} = pay, _state) do
    [
      {[pay], weight: 3, doc: @as_is},
      {[
         {Authorize, overrides: %{amount: a}},
         {Capture,
          overrides: fn _state, [%{events: [%X.Authorized{id: id}]}] ->
            %{authorization_id: id, amount: a}
          end}
       ], doc: @two_steps}
    ]
  end

  # Both targets draw their own entries; "a" refuses every Capture.
  defp targets do
    recorder = start_recorder()
    [X.target("a", recorder, nil, %{fail: %{Capture => :error}}), X.target("b", recorder)]
  end

  defp model do
    module = Module.concat(ExpansionDocReplay, Model)

    if Code.ensure_loaded?(module),
      do: module,
      else: X.define_model!(module, expansions: [{Pay, &documented/2}])
  end

  defp run(extra) do
    X.run(model(), targets(), Keyword.merge([max_commands: 4, shrink: true], extra))
  end

  # The first seed whose run fails, with a replay artifact in a fresh directory.
  defp failing_run! do
    dir = R.tmp_dir!()

    Enum.find_value(1..200, fn seed ->
      case run(seed: seed, replay_dir: dir) do
        {:error, %FailureReport{} = report} -> {seed, report}
        {:ok, _stats} -> nil
      end
    end) || flunk("no seed in 1..200 fails")
  end

  # `%{target name => [{root id, entry, doc}]}`.
  defp docs(report) do
    Map.new(report.trace.expansion, fn {name, choices} ->
      {name, Enum.map(choices, &{&1.root_id, &1.entry, Map.fetch!(&1, :doc)})}
    end)
  end

  test "a replayed failure carries the docs the original run did, per target and root" do
    {_seed, report} = failing_run!()
    path = R.replay_path!(report)

    original = docs(report)

    assert original
           |> Map.values()
           |> List.flatten()
           |> Enum.any?(&match?({_, _, @two_steps}, &1))

    assert {:error, %FailureReport{} = replayed} =
             PropertyDamage.run(
               model: model(),
               targets: targets(),
               only: [replay: path],
               replay_dir: false,
               validate: false
             )

    assert docs(replayed) == original
  end

  test "the artifact file holds no doc: the docs are read from the model" do
    {_seed, report} = failing_run!()
    text = File.read!(R.replay_path!(report))

    assert text =~ "Pay["
    refute text =~ @as_is
    refute text =~ @two_steps
    refute text =~ "doc"
  end
end
