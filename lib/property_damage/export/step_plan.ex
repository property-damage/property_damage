defmodule PropertyDamage.Export.StepPlan do
  @moduledoc false

  # A resolved, target-agnostic plan the HTTP export targets (curl/python/elixir
  # /livebook) consume. `build/2` walks the failure once and hands each target a
  # list of fully resolved steps, so the targets keep only their output syntax
  # and never re-derive placeholder wiring or HTTP specs.
  #
  # Each `Step` carries the reader-facing facts from `FailureReport.Step`
  # (position, flattened index, command, label, failure flag) plus the resolved
  # HTTP view:
  #
  #   * `http_spec` - the command's `HTTPSpec` (nil when the adapter has none).
  #   * `resolved_path_params` / `resolved_body` - the spec's path params and
  #     body with every consumed `%Placeholder{}` replaced by a `%StepPlan.Var{}`
  #     carrying the script variable name. The replacement recurses into lists
  #     and maps, so a placeholder nested in a collection resolves the same as a
  #     top-level one.
  #   * `producer_bindings` - `[{response_path, var_name}]` this command must
  #     bind from its response for downstream consumers (DR-021).
  #
  # The placeholder-structure knowledge lives here; targets match on `%Var{}`
  # and render their own syntax.

  alias PropertyDamage.Export.{Common, HTTPSpec}
  alias PropertyDamage.{FailureReport, Placeholder}
  alias PropertyDamage.Sequence.Position

  defmodule Var do
    @moduledoc false
    # A consumed external value resolved to the script variable a producer step
    # binds. Targets render this in their own syntax (`$var`, `refs["var"]`, ...).
    defstruct [:name]
    @type t :: %__MODULE__{name: String.t()}
  end

  defmodule Step do
    @moduledoc false

    alias PropertyDamage.Export.HTTPSpec
    alias PropertyDamage.Sequence

    @type t :: %__MODULE__{
            position: Sequence.Position.t(),
            flattened_index: non_neg_integer(),
            command: struct(),
            label: String.t() | nil,
            failed?: boolean(),
            http_spec: HTTPSpec.t() | nil,
            resolved_path_params: map(),
            resolved_query_params: map(),
            resolved_body: map() | nil,
            producer_bindings: [{[term()], String.t()}]
          }

    defstruct [
      :position,
      :flattened_index,
      :command,
      :label,
      :failed?,
      :http_spec,
      :resolved_path_params,
      :resolved_query_params,
      :resolved_body,
      :producer_bindings
    ]
  end

  @doc """
  Builds the resolved step plan for a failure report.

  `adapter` supplies `http_spec/2`; pass `nil` when the report has no adapter
  (each step then carries `http_spec: nil` and targets emit their no-mapping
  fallback).
  """
  @spec build(FailureReport.t(), module() | nil) :: [Step.t()]
  def build(%FailureReport{} = report, adapter) do
    commands = Common.extract_commands(report)
    var_map = placeholder_var_map(commands)
    extractions = producer_extractions(commands)

    report
    |> FailureReport.steps()
    |> Enum.map(fn step ->
      spec = get_http_spec(step.command, adapter)

      %Step{
        position: step.position,
        flattened_index: step.flattened_index,
        command: step.command,
        label: step.label,
        failed?: step.failed?,
        http_spec: spec,
        resolved_path_params: resolve_path_params(spec, var_map),
        resolved_query_params: resolve_query_params(spec, var_map),
        resolved_body: resolve_body(spec, step.command, var_map),
        producer_bindings: producer_bindings(extractions, step.flattened_index)
      }
    end)
  end

  @doc """
  Whether a resolved value contains a `Var` anywhere in its list/map structure.

  Targets whose collection rendering delegates to `inspect/1` use this to keep
  placeholder-free collections byte-identical while custom-rendering only the
  collections that actually carry a resolved variable. Non-`Var` structs are not
  descended into (mirroring `resolve_body/3`, which leaves them whole).
  """
  @spec contains_var?(term()) :: boolean()
  def contains_var?(%Var{}), do: true
  def contains_var?(value) when is_list(value), do: Enum.any?(value, &contains_var?/1)
  def contains_var?(%_{}), do: false

  def contains_var?(value) when is_map(value),
    do: Enum.any?(value, fn {_k, v} -> contains_var?(v) end)

  def contains_var?(_value), do: false

  # ============================================================================
  # HTTPSpec Resolution
  # ============================================================================

  defp get_http_spec(_command, nil), do: nil

  defp get_http_spec(command, adapter) do
    if function_exported?(adapter, :http_spec, 2) do
      adapter.http_spec(command, %{})
    else
      nil
    end
  end

  defp resolve_path_params(nil, _var_map), do: %{}

  defp resolve_path_params(%HTTPSpec{path_params: params}, var_map) do
    Map.new(params, fn {key, value} -> {key, tag(value, var_map)} end)
  end

  defp resolve_query_params(nil, _var_map), do: %{}

  defp resolve_query_params(%HTTPSpec{query_params: params}, var_map) do
    Map.new(params, fn {key, value} -> {key, tag(value, var_map)} end)
  end

  defp resolve_body(nil, _command, _var_map), do: nil
  defp resolve_body(%HTTPSpec{body: nil}, _command, _var_map), do: nil
  defp resolve_body(%HTTPSpec{body: body}, _command, _var_map) when map_size(body) == 0, do: nil

  defp resolve_body(%HTTPSpec{body: body}, command, var_map) do
    Map.new(body, fn {key, default} -> {key, tag(Map.get(command, key, default), var_map)} end)
  end

  # Replace every consumed placeholder with the variable a producer binds,
  # recursing into lists and plain maps so nested placeholders resolve too.
  # Non-placeholder structs and scalars are left untouched for the target to
  # render as it always has.
  defp tag(%Placeholder{} = ph, var_map), do: %Var{name: Map.fetch!(var_map, ph.id)}
  defp tag(value, var_map) when is_list(value), do: Enum.map(value, &tag(&1, var_map))
  defp tag(%_{} = struct, _var_map), do: struct

  defp tag(value, var_map) when is_map(value) do
    Map.new(value, fn {k, v} -> {k, tag(v, var_map)} end)
  end

  defp tag(value, _var_map), do: value

  defp producer_bindings(extractions, flattened_index) do
    extractions
    |> Map.get(flattened_index, [])
    |> Enum.map(fn {%Placeholder{path: path}, var} -> {path, var} end)
  end

  # ============================================================================
  # Placeholder Wiring (DR-021)
  # ============================================================================
  #
  # A consumer command field can hold a `%Placeholder{}`: a server-generated
  # value produced by an upstream command. The placeholder carries everything a
  # standalone reproduction script needs to wire it: `position` (the producing
  # command's structured index), `path` (the field within that command's
  # response), and `id` (a stable identity shared by all consumers of the same
  # produced value).

  # All placeholders consumed anywhere in `commands`, de-duplicated by identity
  # and paired with a stable script variable name. First-appearance order.
  @spec placeholder_bindings([struct()]) :: [{Placeholder.t(), String.t()}]
  defp placeholder_bindings(commands) do
    commands
    |> Enum.flat_map(&collect_placeholders/1)
    |> Enum.uniq_by(& &1.id)
    |> Enum.map(&{&1, placeholder_var(&1)})
  end

  # Map from placeholder identity (`id`) to its script variable name.
  @spec placeholder_var_map([struct()]) :: %{reference() => String.t()}
  defp placeholder_var_map(commands) do
    commands
    |> placeholder_bindings()
    |> Map.new(fn {ph, name} -> {ph.id, name} end)
  end

  # Map from a producing command's linear index to the `[{placeholder, var_name}]`
  # it must extract from its response.
  #
  # Only linear (`:prefix`) producers are wired: in a linear sequence the prefix
  # index equals the flattened command index a script iterates. Branch/suffix
  # producers are omitted (standalone scripts are best-effort linear).
  @spec producer_extractions([struct()]) :: %{
          non_neg_integer() => [{Placeholder.t(), String.t()}]
        }
  defp producer_extractions(commands) do
    commands
    |> placeholder_bindings()
    |> Enum.filter(fn {ph, _name} -> match?(%Position{section: :prefix}, ph.position) end)
    |> Enum.group_by(fn {ph, _name} -> ph.position.offset end)
  end

  defp placeholder_var(%Placeholder{event_module: mod, path: path, position: position}) do
    module_part = mod |> Module.split() |> List.last() |> to_string()
    path_part = Enum.map_join(path, "_", &to_string/1)
    idx_part = position_suffix(position)
    sanitize_label("#{module_part}_#{path_part}#{idx_part}")
  end

  defp position_suffix(%Position{section: :prefix, offset: i}), do: "_#{i}"
  defp position_suffix(%Position{section: {:branch, b}, offset: i}), do: "_b#{b}_#{i}"
  defp position_suffix(%Position{section: :suffix, offset: i}), do: "_s#{i}"
  defp position_suffix(_), do: ""

  defp collect_placeholders(%Placeholder{} = ph), do: [ph]

  defp collect_placeholders(%_{} = struct) do
    struct |> Map.from_struct() |> Map.values() |> Enum.flat_map(&collect_placeholders/1)
  end

  defp collect_placeholders(value) when is_map(value) do
    value |> Map.values() |> Enum.flat_map(&collect_placeholders/1)
  end

  defp collect_placeholders(value) when is_list(value) do
    Enum.flat_map(value, &collect_placeholders/1)
  end

  defp collect_placeholders(value) when is_tuple(value) do
    value |> Tuple.to_list() |> Enum.flat_map(&collect_placeholders/1)
  end

  defp collect_placeholders(_other), do: []

  defp sanitize_label(nil), do: "unknown"

  defp sanitize_label(label) when is_binary(label) do
    label
    |> String.replace(~r/[^a-zA-Z0-9_]/, "_")
    |> String.downcase()
  end

  defp sanitize_label(label), do: sanitize_label(to_string(label))
end
