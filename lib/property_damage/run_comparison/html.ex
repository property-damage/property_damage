defmodule PropertyDamage.RunComparison.Html do
  @moduledoc false
  # Single self-contained HTML report for a %RunComparison{} (DR-035).
  #
  # No existing full-document HTML precedent in-tree, so this follows the
  # Export/Diagram pure-string-builder idiom and sets the pattern: inline
  # CSS/JS, no external hosts, static pre-rendered table (readable JS-off), and
  # an embedded versioned JSON blob as the machine-readable source of truth.

  alias PropertyDamage.RunComparison
  alias PropertyDamage.RunComparison.{Encode, Field}
  alias PropertyDamage.Sequence.Position

  @spec render(RunComparison.t()) :: String.t()
  def render(%RunComparison{} = c) do
    data = Encode.encode(c)

    """
    <!DOCTYPE html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>PropertyDamage Run Comparison</title>
    <style>#{css()}</style>
    </head>
    <body>
    <h1>Run Comparison</h1>
    #{guard_banner(c)}
    #{state_warning_banner(c)}
    #{header_section(c)}
    #{runs_section(c)}
    #{ranking_section(c)}
    #{fields_section(c)}
    <script type="application/json" id="run-comparison-data">
    #{Jason.encode!(data)}
    </script>
    <script>#{js()}</script>
    </body>
    </html>
    """
  end

  # ---- Sections -------------------------------------------------------------

  defp guard_banner(%RunComparison{comparable?: true}), do: ""

  defp guard_banner(%RunComparison{guard_violations: violations}) do
    items = Enum.map_join(violations, "", &"<li>#{esc(&1)}</li>")

    """
    <div class="banner incomparable">
    <strong>Runs are not comparable.</strong>
    <ul>#{items}</ul>
    </div>
    """
  end

  defp state_warning_banner(%RunComparison{state_warnings: []}), do: ""

  defp state_warning_banner(%RunComparison{state_warnings: modules}) do
    items = Enum.map_join(modules, "", &"<li class=\"mono\">#{esc(inspect(&1))}</li>")

    """
    <div class="banner incomparable">
    <strong>Possible non-pure projection(s).</strong>
    These projections' derived state varied within an outcome group (same plan,
    same outcome), which usually means an <code>apply/2</code> read a clock,
    counter, or the environment:
    <ul>#{items}</ul>
    </div>
    """
  end

  defp header_section(%RunComparison{header: header}) do
    rev =
      case header[:source_revision] do
        {sha, dirty?} -> "#{esc(sha)}#{if dirty?, do: " (dirty)", else: ""}"
        _ -> "—"
      end

    """
    <section class="repro">
    <h2>Reproducibility</h2>
    <dl>
    <dt>Model</dt><dd>#{esc(inspect(header[:model]))}</dd>
    <dt>Adapter</dt><dd>#{esc(inspect(header[:adapter]))}</dd>
    <dt>Plan fingerprint</dt><dd class="mono">#{esc(header[:plan_fingerprint])}</dd>
    <dt>Source revision</dt><dd class="mono">#{rev}</dd>
    <dt>Timestamp (UTC)</dt><dd>#{esc(timestamp(header[:timestamp]))}</dd>
    </dl>
    </section>
    """
  end

  defp runs_section(%RunComparison{header: header}) do
    rows =
      header[:runs]
      |> Enum.with_index()
      |> Enum.map_join("", fn {run, i} ->
        """
        <tr class="#{outcome_class(run.outcome)}">
        <td>##{i}</td>
        <td>#{esc(to_string(run.outcome))}</td>
        <td>#{esc(inspect(run.seed))}</td>
        <td>#{esc(inspect(run.run_number))}</td>
        <td class="mono corr">#{esc(inspect(run.run_nonce))}</td>
        <td>#{esc(inspect(run.mint_epoch))}</td>
        <td>#{esc(to_string(run.plan_source))}</td>
        </tr>
        """
      end)

    """
    <section class="runs">
    <h2>Runs</h2>
    <p class="hint">The per-run <span class="corr">nonce</span> is the join key
    into your SUT logs for the client-minted correlation ids.</p>
    <table>
    <thead><tr>
    <th>Run</th><th>Outcome</th><th>Seed</th><th>Run #</th>
    <th>Nonce</th><th>Epoch</th><th>Plan source</th>
    </tr></thead>
    <tbody>#{rows}</tbody>
    </table>
    </section>
    """
  end

  defp ranking_section(%RunComparison{ranking: []}) do
    ~s(<section class="ranking"><h2>Ranked differences</h2><p class="hint">No discriminating differences found.</p></section>)
  end

  defp ranking_section(%RunComparison{ranking: ranking} = c) do
    items =
      Enum.map_join(ranking, "", fn field ->
        "<li>#{location_label(field.location)} " <>
          "<span class=\"prov prov-#{field.provenance}\">#{field.provenance}</span></li>"
      end)

    """
    <section class="ranking">
    <h2>Ranked differences</h2>
    <p class="hint">Most discriminating first: fields stable within each outcome
    group but different between groups.</p>
    <ol>#{items}</ol>
    #{mixed_note(c)}
    </section>
    """
  end

  defp mixed_note(%RunComparison{mixed_failure_signatures: []}), do: ""

  defp mixed_note(%RunComparison{mixed_failure_signatures: sigs}) do
    ~s(<p class="warn">Warning: the failing runs carry #{length(sigs)} distinct failure signatures; ranking treats them as one group.</p>)
  end

  defp fields_section(%RunComparison{comparable?: false}), do: ""

  defp fields_section(%RunComparison{fields: fields, traces: traces}) do
    trace_count = length(traces)
    header_cells = Enum.map_join(0..(trace_count - 1), "", &"<th>##{&1}</th>")

    rows =
      fields
      |> Enum.reject(&(&1.classification == :uniform))
      |> Enum.map_join("", &field_row(&1, trace_count))

    """
    <section class="fields">
    <h2>Aligned field differences</h2>
    <table>
    <thead><tr><th>Location</th><th>Provenance</th><th>Class</th>#{header_cells}</tr></thead>
    <tbody>#{rows}</tbody>
    </table>
    </section>
    """
  end

  defp field_row(%Field{} = f, trace_count) do
    cells =
      Enum.map_join(0..(trace_count - 1), "", fn i ->
        ~s(<td class="mono">#{esc(display(Map.get(f.values, i, :absent)))}</td>)
      end)

    """
    <tr class="#{row_class(f.classification)}">
    <td>#{location_label(f.location)}</td>
    <td><span class="prov prov-#{f.provenance}">#{f.provenance}</span></td>
    <td>#{f.classification}</td>
    #{cells}
    </tr>
    """
  end

  # ---- Value / location rendering -------------------------------------------

  defp location_label({:command, position, path}) do
    "#{position_label(position)} <span class=\"mono\">cmd#{path_label(path)}</span>"
  end

  defp location_label({:event, position, key, _row, path}) do
    "#{position_label(position)} <span class=\"mono\">#{esc(inspect(key))}#{path_label(path)}</span>"
  end

  defp location_label({:state, position, projection, path}) do
    "#{position_label(position)} <span class=\"mono\">state #{esc(inspect(projection))}#{path_label(path)}</span>"
  end

  defp position_label(%Position{section: :prefix, offset: o}), do: "prefix[#{o}]"
  defp position_label(%Position{section: :suffix, offset: o}), do: "suffix[#{o}]"
  defp position_label(%Position{section: {:branch, b}, offset: o}), do: "branch#{b}[#{o}]"

  defp path_label([]), do: ""
  defp path_label(path), do: "." <> Enum.map_join(path, ".", &to_string/1)

  defp display(:absent), do: "(absent)"
  defp display(v) when is_binary(v), do: v
  defp display(v) when is_number(v), do: to_string(v)
  defp display(v), do: inspect(v)

  defp timestamp(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp timestamp(_), do: "—"

  defp outcome_class(:pass), do: "pass"
  defp outcome_class(:fail), do: "fail"
  defp outcome_class(_), do: ""

  defp row_class(:discriminating), do: "diff-discriminating"
  defp row_class(:comparability_violation), do: "diff-violation"
  defp row_class(_), do: "diff-other"

  # HTML-escape text for safe embedding.
  defp esc(nil), do: ""
  defp esc(value) when not is_binary(value), do: esc(to_string(value))

  defp esc(value) do
    value
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end

  # ---- Static assets --------------------------------------------------------

  defp css do
    """
    :root { color-scheme: light dark; }
    body { font-family: system-ui, sans-serif; margin: 2rem; line-height: 1.4; }
    h1 { font-size: 1.6rem; } h2 { font-size: 1.2rem; margin-top: 2rem; }
    .mono { font-family: ui-monospace, monospace; font-size: 0.85em; }
    .hint { color: #666; font-size: 0.9em; }
    .warn { color: #b45309; font-weight: 600; }
    table { border-collapse: collapse; width: 100%; margin-top: 0.5rem; }
    th, td { border: 1px solid #ccc; padding: 0.3rem 0.5rem; text-align: left; vertical-align: top; }
    th { background: rgba(127,127,127,0.12); }
    dl { display: grid; grid-template-columns: max-content 1fr; gap: 0.2rem 1rem; }
    dt { font-weight: 600; }
    .banner.incomparable { background: #fee2e2; color: #991b1b; padding: 1rem; border-radius: 6px; }
    tr.pass td { background: rgba(34,197,94,0.10); }
    tr.fail td { background: rgba(239,68,68,0.10); }
    tr.diff-discriminating td { background: rgba(245,158,11,0.18); }
    tr.diff-violation td { background: rgba(239,68,68,0.18); }
    .corr { font-weight: 600; }
    .prov { font-size: 0.75em; padding: 0.05rem 0.4rem; border-radius: 999px; border: 1px solid currentColor; }
    .prov-run_scoped { color: #2563eb; }
    .prov-server_resolved { color: #b45309; }
    .prov-plan_generated { color: #6b7280; }
    """
  end

  defp js do
    """
    // Progressive enhancement only; the report is fully readable without JS.
    document.querySelectorAll('h2').forEach(function (h) {
      h.style.cursor = 'pointer';
      h.addEventListener('click', function () {
        var next = h.nextElementSibling;
        while (next && next.tagName !== 'H2') {
          next.hidden = !next.hidden;
          next = next.nextElementSibling;
        }
      });
    });
    """
  end
end
