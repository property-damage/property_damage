defmodule PropertyDamage.RunComparison.Encode do
  @moduledoc false
  # The defined, versioned JSON schema for a %RunComparison{} (DR-035).
  #
  # %RunComparison{} holds atoms, tuples ({:branch, id} sections), DateTimes, and
  # arbitrary command/event structs that Jason cannot encode as-is. `encode/1`
  # produces a pure JSON-able map (string keys, only strings/numbers/bools/lists/
  # maps) that round-trips through Jason exactly, so it is a stable
  # machine-readable source of truth embedded in the HTML report:
  #
  #   - positions   -> %{"section" => "prefix" | "suffix" | %{"branch" => id},
  #                       "offset" => n}
  #   - structs     -> %{"struct" => "Module", "fields" => %{...}}
  #   - tuples      -> %{"tuple" => [...]}
  #   - non-JSON    -> %{"inspect" => "..."} (pids, refs, funs, ...)
  #   - atoms       -> strings (nil/true/false pass through)
  #
  # The blob carries a `schema_version`; bump it on any incompatible change.

  alias PropertyDamage.RunComparison
  alias PropertyDamage.RunComparison.Field
  alias PropertyDamage.Sequence.Position

  @schema_version 1

  @spec encode(RunComparison.t()) :: map()
  def encode(%RunComparison{} = c) do
    %{
      "schema_version" => @schema_version,
      "comparable" => c.comparable?,
      "guard_violations" => c.guard_violations,
      "groups" => %{
        "passing" => c.groups.passing,
        "failing" => c.groups.failing
      },
      "mixed_failure_signatures" => Enum.map(c.mixed_failure_signatures, &enc/1),
      "header" => enc(c.header),
      "fields" => Enum.map(c.fields, &enc_field/1),
      "ranking" => Enum.map(c.ranking, &enc_field/1)
    }
  end

  @doc "The current schema version of the embedded JSON blob."
  @spec schema_version() :: pos_integer()
  def schema_version, do: @schema_version

  defp enc_field(%Field{} = f) do
    %{
      "location" => enc_location(f.location),
      "provenance" => to_string(f.provenance),
      "classification" => to_string(f.classification),
      "differs" => f.differs?,
      "values" => enc_values(f.values)
    }
  end

  defp enc_location({:command, position, path}) do
    %{"kind" => "command", "position" => enc(position), "path" => Enum.map(path, &enc/1)}
  end

  defp enc_location({:event, position, key, row_index, path}) do
    %{
      "kind" => "event",
      "position" => enc(position),
      "event_key" => enc(key),
      "row" => row_index,
      "path" => Enum.map(path, &enc/1)
    }
  end

  defp enc_values(values) do
    Map.new(values, fn {i, v} -> {Integer.to_string(i), enc(v)} end)
  end

  # ---- Generic term encoding ------------------------------------------------

  defp enc(%Position{section: section, offset: offset}) do
    %{"section" => enc_section(section), "offset" => offset}
  end

  defp enc(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp enc(%{__struct__: mod} = struct) do
    %{"struct" => inspect(mod), "fields" => enc(Map.from_struct(struct))}
  end

  defp enc(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {enc_key(k), enc(v)} end)
  end

  defp enc(list) when is_list(list), do: Enum.map(list, &enc/1)

  defp enc(tuple) when is_tuple(tuple) do
    %{"tuple" => tuple |> Tuple.to_list() |> Enum.map(&enc/1)}
  end

  defp enc(nil), do: nil
  defp enc(bool) when is_boolean(bool), do: bool
  defp enc(atom) when is_atom(atom), do: to_string(atom)
  defp enc(value) when is_number(value) or is_binary(value), do: value
  defp enc(other), do: %{"inspect" => inspect(other)}

  defp enc_section(:prefix), do: "prefix"
  defp enc_section(:suffix), do: "suffix"
  defp enc_section({:branch, id}), do: %{"branch" => id}

  defp enc_key(k) when is_atom(k), do: to_string(k)
  defp enc_key(k) when is_binary(k), do: k
  defp enc_key(k) when is_integer(k), do: Integer.to_string(k)
  defp enc_key(k), do: inspect(k)
end
