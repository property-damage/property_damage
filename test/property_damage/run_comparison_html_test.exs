defmodule PropertyDamage.RunComparisonHtmlTest do
  @moduledoc "DR-035: the self-contained HTML report + embedded versioned JSON."
  use ExUnit.Case, async: true

  alias PropertyDamage.EventLog.Entry
  alias PropertyDamage.{RunComparison, RunTrace, Sequence}
  alias PropertyDamage.RunComparison.Encode

  defmodule Cmd, do: defstruct([:n])
  defmodule Result, do: defstruct([:status])

  @ts ~U[2026-07-03 12:00:00Z]

  defp plan, do: Sequence.linear([%Cmd{n: 1}])

  defp entry(ev), do: %Entry{timestamp: 0, command_index: 0, event: ev, source: :command}

  defp comparison do
    t0 =
      RunTrace.new(
        plan: plan(),
        model: __MODULE__.Model,
        adapter: __MODULE__.Adapter,
        seed: 1,
        run_number: 0,
        run_nonce: 111,
        mint_epoch: 0,
        timestamp: @ts,
        source_revision: {"abc1234", false},
        plan_source: :generated,
        event_log: [entry(%Result{status: :ok})],
        outcome: :pass
      )

    t1 =
      RunTrace.new(
        plan: plan(),
        model: __MODULE__.Model,
        adapter: __MODULE__.Adapter,
        seed: 1,
        run_number: 0,
        run_nonce: 222,
        mint_epoch: 0,
        timestamp: @ts,
        source_revision: {"abc1234", false},
        plan_source: :generated,
        event_log: [entry(%Result{status: :error})],
        outcome: {:fail, {:check_failed, :Inv, "boom"}}
      )

    RunComparison.compare([t0, t1])
  end

  test "the embedded JSON is a versioned, Jason-round-tripping blob" do
    data = Encode.encode(comparison())

    # The encoder produces a pure JSON-able map that round-trips exactly.
    assert data["schema_version"] == Encode.schema_version()
    assert Jason.decode!(Jason.encode!(data)) == data
  end

  test "to_html embeds the same JSON and is self-contained (no external URLs)" do
    html = RunComparison.to_html(comparison())

    # No external hosts (repo self-sufficiency rule).
    refute html =~ "http://"
    refute html =~ "https://"
    refute html =~ "//cdn"

    # The embedded blob decodes to the encoder's output.
    blob =
      html
      |> String.split(~s(<script type="application/json" id="run-comparison-data">))
      |> Enum.at(1)
      |> String.split("</script>")
      |> Enum.at(0)
      |> String.trim()

    assert Jason.decode!(blob) == Encode.encode(comparison())
  end

  test "renders the reproducibility header and the discriminating field" do
    html = RunComparison.to_html(comparison())

    assert html =~ "Run Comparison"
    assert html =~ "Reproducibility"
    # Per-run nonces surfaced as correlation ids.
    assert html =~ "111"
    assert html =~ "222"
    # The discriminating status field is present with its values.
    assert html =~ "status"
    assert html =~ "error"
  end

  describe "golden" do
    @golden Path.join([__DIR__, "..", "support", "fixtures", "run_comparison", "basic.html"])

    test "HTML output matches the golden" do
      html = RunComparison.to_html(comparison())

      if System.get_env("CAPTURE_GOLDENS") == "1" do
        File.mkdir_p!(Path.dirname(@golden))
        File.write!(@golden, html)
        assert true
      else
        assert html == File.read!(@golden),
               "HTML drifted from golden. Re-baseline with CAPTURE_GOLDENS=1 only if intended."
      end
    end
  end
end
