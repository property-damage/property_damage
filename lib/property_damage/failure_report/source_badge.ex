defmodule PropertyDamage.FailureReport.SourceBadge do
  @moduledoc false
  # The three-letter badge a printed event log puts before an event to say
  # where the event came from (`PropertyDamage.EventLog.Entry` lists the
  # sources). The terminal report and the timeline print the same badges, so
  # the table lives here once; a source neither knows prints as `???`.

  @badges %{
    command: {"CMD", "\e[32m"},
    injector: {"INJ", "\e[33m"},
    nemesis: {"NEM", "\e[31m"},
    mock: {"MOC", "\e[35m"},
    stutter: {"STU", "\e[34m"},
    resource_poller: {"POL", "\e[36m"},
    telemetry: {"TEL", "\e[36m"},
    injected: {"EMT", "\e[32m"}
  }

  @unknown {"???", "\e[2m"}

  @doc false
  # The badge for `source`, wrapped in its ANSI color when `color` is true.
  @spec badge(atom(), boolean()) :: String.t()
  def badge(source, color) do
    {text, code} = Map.get(@badges, source, @unknown)
    if color, do: code <> text <> "\e[0m", else: text
  end
end
