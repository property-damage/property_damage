defmodule PropertyDamage.Next.Report do
  @moduledoc """
  What one run of `PropertyDamage.Next.run/1` saw, in one place.

  `run/1` returns it as `{:ok, report}` after a passing run and inside the
  failure of a failing one (`PropertyDamage.Next.Failure`), so a reader finds
  the same facts in both cases. A report is a plain struct with these
  fields:

    * `plans` - the number of plans the search executed
    * `withdrawn` - the slots withdrawn while building the plans, each as
      `%{key: key, command: module}`. For a failing run it is the failure's
      own list. A plan the search draws from a seed never withdraws a slot,
      so the list is empty unless the run failed on a shrunk plan
    * `kept` - the sites where PD's engine drew a dependent StreamData
      generator it cannot fit (see `PropertyDamage.Next.Plan`)
    * `layers` - one `%{layer: name, specs_changed: n}` per layer applied to
      the model's specs, in application order. A layer that matched nothing
      shows `specs_changed: 0`, which is how a misspelled layer shows up. The
      name is `"Mod.fun/arity"` for a captured function
    * `never_drawn` - one `%{spec: id, command: module, reason: reason}` for
      each spec no step of the search plans came from. The reason is
      `:never_eligible` when the spec's `when:` was false at every slot the
      search evaluated, and `:never_chosen` when it held at some slot but
      the draw never picked the spec
    * `assigns` - `%{target => rows}`, where the target is the adapter module
      and each row is `%{command: module, key: atom, set: n, acknowledged: n}`:
      how many executed steps of the search plans set the assign, and how many
      times the adapter acknowledged it. Only keys some step set have a row.
      The map is keyed by target so a run with several targets needs no new
      shape

  The counts exist to catch an assign that no port acts on: a fault the model
  draws and the adapter silently ignores, such as a misspelled clause. See
  `PropertyDamage.Next.Runtime.ack/2`.

  `format/1` renders a report as text.
  """

  alias PropertyDamage.Next.StepSpec

  defstruct plans: 0, withdrawn: [], kept: [], layers: [], never_drawn: [], assigns: %{}

  @type layer :: %{layer: String.t(), specs_changed: non_neg_integer()}
  @type never_drawn :: %{
          spec: pos_integer(),
          command: module(),
          reason: :never_eligible | :never_chosen
        }
  @type assign_row :: %{
          command: module(),
          key: atom(),
          set: non_neg_integer(),
          acknowledged: non_neg_integer()
        }

  @type t :: %__MODULE__{
          plans: non_neg_integer(),
          withdrawn: [%{key: term(), command: module()}],
          kept: [map()],
          layers: [layer()],
          never_drawn: [never_drawn()],
          assigns: %{module() => [assign_row()]}
        }

  @doc false
  # The layers `specs` went through, from the `history` each spec records:
  # the layer at each position of the history, with the number of specs
  # that layer changed.
  @spec layers([StepSpec.t()]) :: [layer()]
  def layers(specs) do
    histories = Enum.map(specs, & &1.history)
    longest = Enum.max_by(histories, &length/1, fn -> [] end)

    longest
    |> Enum.with_index()
    |> Enum.map(fn {{fun, _outcome}, index} ->
      changed =
        Enum.count(histories, fn history ->
          match?({_fun, :changed}, Enum.at(history, index))
        end)

      %{layer: layer_name(fun), specs_changed: changed}
    end)
  end

  defp layer_name(fun) do
    info = Function.info(fun)
    name = Atom.to_string(info[:name])

    if String.starts_with?(name, "-") do
      "anonymous function in #{inspect(info[:module])} (#{name}/#{info[:arity]})"
    else
      "#{inspect(info[:module])}.#{name}/#{info[:arity]}"
    end
  end

  @doc """
  Renders `report` as text: the same lines for the same report.

  The text has one section per field, each with its header on a line of its
  own: `Layers`, `Withdrawn`, `Kept`, `Never drawn` and `Assigns`. A layer
  line reads `<layer>: specs changed: <n>`, an assign line
  `<command> <key>: set <n>, acknowledged <n>`, and a never-drawn line
  `<command> (spec <id>): never eligible` or `never chosen`. An empty
  section reads `none`.
  """
  @spec format(t()) :: String.t()
  def format(%__MODULE__{} = report) do
    [
      ["Run report", "plans: #{report.plans}"],
      section("Layers", Enum.map(report.layers, &layer_line/1)),
      section("Withdrawn", Enum.map(report.withdrawn, &withdrawn_line/1)),
      section("Kept", Enum.map(report.kept, &kept_line/1)),
      section("Never drawn", Enum.map(report.never_drawn, &never_drawn_line/1)),
      assigns_section(report.assigns)
    ]
    |> Enum.map_join("\n\n", &Enum.join(&1, "\n"))
    |> Kernel.<>("\n")
  end

  defp section(header, []), do: [header, "  none"]
  defp section(header, lines), do: [header | Enum.map(lines, &("  " <> &1))]

  defp layer_line(%{layer: layer, specs_changed: n}), do: "#{layer}: specs changed: #{n}"

  defp withdrawn_line(%{key: key, command: command}),
    do: "#{inspect(command)} at step #{inspect(key)}"

  defp kept_line(%{site: site, command: command, key: key}),
    do: "#{site} #{inspect(command)} #{key}"

  defp never_drawn_line(%{spec: id, command: command, reason: reason}),
    do: "#{inspect(command)} (spec #{id}): #{reason_text(reason)}"

  defp reason_text(:never_eligible), do: "never eligible"
  defp reason_text(:never_chosen), do: "never chosen"

  defp assigns_section(assigns) do
    header = [
      "Assigns",
      "  every assign a port acts on must be acknowledged by that port at least once"
    ]

    rows =
      assigns
      |> Enum.sort_by(fn {target, _rows} -> inspect(target) end)
      |> Enum.flat_map(fn {target, rows} ->
        ["  target #{inspect(target)}" | Enum.map(rows, &("    " <> assign_line(&1)))]
      end)

    case rows do
      [] -> header ++ ["  none"]
      rows -> header ++ rows
    end
  end

  defp assign_line(%{command: command, key: key, set: set, acknowledged: acknowledged}),
    do: "#{inspect(command)} #{key}: set #{set}, acknowledged #{acknowledged}"
end
