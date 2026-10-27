defmodule PropertyDamage.ReplayArtifactKeyRefusalTest.Fixtures do
  @moduledoc false
  # Models whose one Mark root runs one Tag leaf; the Tag's payload holds a
  # value no file can hold as a map key: a function, a pid, a reference, a
  # function keying a map nested in a list and a map, and a pid in a MapSet.
  alias PropertyDamage.Test.ReplayFixtures, as: R

  def noop, do: :ok

  def payload(:function_key), do: %{&__MODULE__.noop/0 => 1}
  def payload(:pid_key), do: %{self() => 1}
  def payload(:reference_key), do: %{make_ref() => 1}
  def payload(:nested_key), do: [%{1 => %{&__MODULE__.noop/0 => :x}}]
  def payload(:mapset_pid), do: MapSet.new([self()])

  def mark_as_tag(poison, %R.Mark{n: n}, _state),
    do: [[{R.Tag, overrides: %{n: n, payload: payload(poison)}}]]

  for {name, poison} <- [
        FunctionKeyModel: :function_key,
        PidKeyModel: :pid_key,
        ReferenceKeyModel: :reference_key,
        NestedKeyModel: :nested_key,
        MapSetPidModel: :mapset_pid
      ] do
    defmodule Module.concat(__MODULE__, name) do
      @moduledoc false
      @behaviour PropertyDamage.Model

      alias PropertyDamage.ReplayArtifactKeyRefusalTest.Fixtures
      alias PropertyDamage.Test.ReplayFixtures, as: R

      @impl true
      def commands, do: [R.Mark]
      @impl true
      def command_sequence_projection, do: R.World
      @impl true
      def check_projections, do: [R.Tally]
      @impl true
      def simulator, do: R

      @impl true
      def expansions, do: [{R.Mark, &Fixtures.mark_as_tag(unquote(poison), &1, &2)}]
    end
  end
end

defmodule PropertyDamage.ReplayArtifactKeyRefusalTest do
  # A value no file can hold refuses the artifact wherever it sits in a
  # command field, a map key included: the run returns its failure report
  # with the refusal, naming the target, the root, the leaf and the path to
  # the map with the key marked, and writes no file.
  use ExUnit.Case, async: true

  alias PropertyDamage.ReplayArtifactKeyRefusalTest.Fixtures
  alias PropertyDamage.Test.ExpansionFor, as: F
  alias PropertyDamage.Test.ReplayFixtures, as: R

  defp refused(model) do
    dir = R.tmp_dir!()
    targets = [R.target("ref"), R.target("second", :random, %{bug: true})]

    assert {:error, report} =
             R.run(model, targets, seed: 1, max_runs: 1, max_commands: 3, replay_dir: dir)

    F.drain()

    assert report.kind == :diverged
    assert report.variant.name == "second"
    assert report.replay_path == nil
    assert R.files(dir) == []
    assert {:refused, %{target: "second", root: 0, leaf: 0, field: field}} = report.replay

    [label, last] = R.last_lines(report, 2)
    assert label == "# Replay the shrunk failure:"
    assert last =~ "refused"
    assert last =~ "payload"
    assert last =~ "[key "

    field
  end

  test "a function as a map key refuses the artifact, naming the map and the key" do
    assert refused(Fixtures.FunctionKeyModel) ==
             [:payload, {:key, inspect(&Fixtures.noop/0)}]
  end

  test "a pid as a map key refuses the artifact, naming the map and the key" do
    assert [:payload, {:key, "#PID<" <> _}] = refused(Fixtures.PidKeyModel)
  end

  test "a reference as a map key refuses the artifact, naming the map and the key" do
    assert [:payload, {:key, "#Reference<" <> _}] = refused(Fixtures.ReferenceKeyModel)
  end

  test "a function keying a nested map refuses the artifact, naming the path to that map" do
    assert refused(Fixtures.NestedKeyModel) ==
             [:payload, 0, 1, {:key, inspect(&Fixtures.noop/0)}]
  end

  test "a pid in a MapSet refuses the artifact, naming the set's map and the key" do
    assert [:payload, :map, {:key, "#PID<" <> _}] = refused(Fixtures.MapSetPidModel)
  end
end
