# The Inspect implementation lives in its own file: it calls the formatter,
# and the formatter reads the report, so keeping it beside the struct would
# tie the struct's file into a dependency cycle with every renderer.
defimpl Inspect, for: PropertyDamage.FailureReport do
  def inspect(report, opts) do
    # For IEx/IO.inspect, show the formatted report instead of raw struct. The
    # formatters assume a report built by FailureReport.new (real sequence and
    # timestamp); a hand-built or partially-deserialized struct can crash them,
    # so guard with a minimal, always-safe fallback rather than letting inspect/1
    # blow up into an #Inspect.Error<...>.
    if opts.limit == :infinity or opts.pretty do
      # User wants detailed output - show formatted report
      formatted = PropertyDamage.FailureReport.Formatter.format(report, :terminal, color: false)
      Inspect.Algebra.concat(["#FailureReport<\n", formatted, ">"])
    else
      # Brief output - show compact format
      compact = PropertyDamage.FailureReport.Formatter.format(report, :compact)
      Inspect.Algebra.concat(["#FailureReport<", compact, ">"])
    end
  rescue
    error -> fallback(report, Exception.message(error))
  catch
    kind, value -> fallback(report, Exception.format_banner(kind, value))
  end

  # The summary names the error it replaced, on one line.
  defp fallback(report, error) do
    type = PropertyDamage.FailureReport.kind(report)

    Inspect.Algebra.concat([
      "#FailureReport<",
      "seed: #{inspect(PropertyDamage.FailureReport.seed(report))}, ",
      "type: #{inspect(type)}, ",
      "failed_at: #{inspect(report.failed_at_index)}, ",
      "error: #{String.replace(error, ~r/\s*\n\s*/, " ")}",
      ">"
    ])
  end
end
