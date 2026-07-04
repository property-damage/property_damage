defmodule PropertyDamage.CommandLabelTest do
  @moduledoc """
  DR-028 amendment (served/servant clean break, P7): `Command.label/2` is wired
  into failure reporting. It was a declared optional callback with ZERO consumers
  in `lib/` (only the `@callback` + a direct unit-test call). P7 makes it render.

  Design (locked):

    * Labels are computed lazily, only when a `FailureReport` is built (`new/1`),
      by folding the shrunk sequence through `command_sequence_projection` with the
      same `apply(command)`-then-`apply(events)` recipe generation uses. So each
      command's label sees the projection pre-state generation saw.
    * The label store is keyed by the FLATTENED command index (the 0..n-1 index of
      `Sequence.to_list/1`), which every formatter/exporter already iterates with.
    * A `nil` label (or a command without `label/2`) contributes nothing.

  These are failing-first behaviour tests: on HEAD before P7 nothing renders a
  label, so each assertion that the label text appears is RED.
  """
  use ExUnit.Case, async: false

  alias PropertyDamage.{Export, Failure, FailureReport, Sequence}
  alias PropertyDamage.FailureReport.Formatter

  # --- Fixtures ---------------------------------------------------------------

  # Counts every projection apply. The simulator emits no events, so during the
  # label fold `apply/2` is called once per command and `count` equals the number
  # of PRECEDING commands when a command's label is computed.
  defmodule LabelState do
    @moduledoc false
    @behaviour PropertyDamage.Model.Projection

    @impl true
    def init, do: %{count: 0}

    @impl true
    def apply(%{count: c} = state, _command_or_event), do: %{state | count: c + 1}
  end

  # State-dependent label: proves the pre-state fold is real (the count rendered
  # must match the command's position, not a constant).
  defmodule Tick do
    @moduledoc false
    use PropertyDamage.Command

    defstruct []

    @impl true
    def generator(_overrides \\ %{}), do: StreamData.constant(%{})

    @impl true
    def label(%{count: c}, %__MODULE__{}), do: "tick #{c}"
  end

  # State-independent label that returns nil for the non-failing instance, to
  # prove nil labels are skipped and only the offending command is annotated.
  defmodule Divide do
    @moduledoc false
    use PropertyDamage.Command

    defstruct [:divisor]

    @impl true
    def generator(_overrides \\ %{}), do: StreamData.constant(%{})

    @impl true
    def label(_state, %__MODULE__{divisor: 0}), do: "divide by zero"
    def label(_state, %__MODULE__{}), do: nil
  end

  defmodule LabelModel do
    @moduledoc false
    @behaviour PropertyDamage.Model
    @behaviour PropertyDamage.Model.Simulator

    @impl true
    def commands, do: [Tick, Divide]

    @impl true
    def command_sequence_projection, do: LabelState

    @impl true
    def simulator, do: __MODULE__

    @impl PropertyDamage.Model.Simulator
    def simulate(_command, _state), do: []
  end

  defp report_for(sequence, opts \\ []) do
    FailureReport.new(
      [
        seed: 4242,
        run_number: 0,
        original_sequence: sequence,
        shrunk_sequence: sequence,
        failed_at_index: Keyword.get(opts, :failed_at_index, 0),
        failure_reason: Failure.assertion_failed(:SomeInvariant, "boom"),
        model: LabelModel
      ] ++ Keyword.delete(opts, :failed_at_index)
    )
  end

  # --- The label store (keyed by flattened index) -----------------------------

  describe "command_labels store" do
    test "is keyed by flattened index with only non-nil labels" do
      seq = Sequence.linear([%Divide{divisor: 5}, %Divide{divisor: 0}])
      report = report_for(seq, failed_at_index: 1)

      # Only the divide-by-zero command (flat index 1) is labeled.
      assert report.command_labels == %{1 => "divide by zero"}
    end

    test "computes each label against the projection pre-state (fold, not constant)" do
      seq = Sequence.linear([%Tick{}, %Tick{}, %Tick{}])
      report = report_for(seq)

      assert report.command_labels == %{0 => "tick 0", 1 => "tick 1", 2 => "tick 2"}
    end

    test "keys span prefix, branches, and suffix in flattened (to_list) order" do
      # Flattened: [Tick(0), Divide0(1), Tick(2), Tick(3)]
      seq = Sequence.branching([%Tick{}], [[%Divide{divisor: 0}], [%Tick{}]], [%Tick{}])
      report = report_for(seq)

      assert report.command_labels == %{
               0 => "tick 0",
               1 => "divide by zero",
               2 => "tick 2",
               3 => "tick 3"
             }
    end
  end

  # --- Rendering: terminal / markdown / json ----------------------------------

  describe "FailureReport.Formatter renders labels" do
    setup do
      seq = Sequence.linear([%Divide{divisor: 5}, %Divide{divisor: 0}])
      {:ok, report: report_for(seq, failed_at_index: 1)}
    end

    test "terminal output shows the label next to the offending command", %{report: report} do
      out = Formatter.format(report, :terminal, color: false)
      assert out =~ "divide by zero"
    end

    test "markdown output shows the label", %{report: report} do
      out = Formatter.format(report, :markdown, [])
      assert out =~ "divide by zero"
    end

    test "json output carries the label per command", %{report: report} do
      out = Formatter.format(report, :json, [])
      decoded = Jason.decode!(out)
      labels = decoded |> get_in(["sequence"]) |> Enum.map(& &1["label"])
      assert "divide by zero" in labels
    end
  end

  # --- Rendering: exported reproductions --------------------------------------

  describe "Export embeds labels as comments" do
    setup do
      seq = Sequence.linear([%Divide{divisor: 5}, %Divide{divisor: 0}])
      {:ok, report: report_for(seq, failed_at_index: 1)}
    end

    test "ExUnit export comments the label next to the command", %{report: report} do
      code = Export.to_exunit(report)
      assert code =~ "divide by zero"
    end

    test "Elixir script export comments the label", %{report: report} do
      script = Export.to_script(report, :elixir, base_url: "http://localhost:4000")
      assert script =~ "divide by zero"
    end

    test "Livebook export comments the label", %{report: report} do
      notebook = Export.to_livebook(report, base_url: "http://localhost:4000")
      assert notebook =~ "divide by zero"
    end
  end
end
