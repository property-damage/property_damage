defmodule PropertyDamage.Differential.Baseline do
  @moduledoc """
  Baseline file handling for time-separated differential testing.

  Baselines store the results of a test run (command sequences and their results)
  for later comparison against other implementations.

  ## File Format

  Baselines are stored as JSON files containing:

  - Metadata (creation time, model, target info)
  - Command sequences (as serialized structs)
  - Results per command
  - Timing data
  - Aggregate metrics
  """

  @type run_data :: %{
          commands: [struct()],
          results: [term()],
          timings: [number()],
          event_log: [struct()]
        }

  @type t :: %__MODULE__{
          created_at: DateTime.t(),
          model: String.t(),
          model_version: String.t() | nil,
          target_name: String.t(),
          seed: integer(),
          runs: [run_data()],
          aggregate_metrics: map()
        }

  defstruct [
    :created_at,
    :model,
    :model_version,
    :target_name,
    :seed,
    :runs,
    :aggregate_metrics
  ]

  @doc """
  Export a differential testing result to a baseline file.
  """
  @spec export(PropertyDamage.Differential.Result.t(), map(), Path.t()) :: :ok | {:error, term()}
  def export(result, config, path) do
    # Get the first target's data for export
    # In typical usage, there's only one target when exporting
    target_name = hd(result.targets)
    metrics = Map.get(result.metrics, target_name, %{})

    baseline = %{
      created_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      model: inspect(config.model),
      model_version: get_model_version(config.model),
      target_name: target_name,
      seed: result.seed,
      # Will be populated from the run data
      runs: [],
      aggregate_metrics: metrics
    }

    json = encode_baseline(baseline)

    case File.write(path, json) do
      :ok -> :ok
      {:error, reason} -> {:error, {:write_failed, reason}}
    end
  end

  @doc """
  Export run data directly to a baseline file.

  This is called during sequential execution to capture actual run data.
  """
  @spec export_run_data(map(), map(), Path.t()) :: :ok | {:error, term()}
  def export_run_data(run_data, config, path) do
    target_name =
      config.targets
      |> List.first()
      |> elem(0)
      |> inspect()

    metrics = calculate_aggregate_metrics(run_data)

    baseline_data = %{
      created_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      model: inspect(config.model),
      model_version: get_model_version(config.model),
      target_name: target_name,
      seed: config.seed,
      runs: serialize_runs(run_data.runs),
      aggregate_metrics: metrics
    }

    json = encode_baseline(baseline_data)

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, json) do
      :ok
    else
      {:error, reason} -> {:error, {:write_failed, reason}}
    end
  end

  @doc """
  Load a baseline file for comparison.
  """
  @spec load(Path.t()) :: {:ok, t()} | {:error, term()}
  def load(path) do
    with {:ok, json} <- File.read(path),
         {:ok, data} <- decode_baseline(json) do
      baseline = %__MODULE__{
        created_at: parse_datetime(data["created_at"]),
        model: data["model"],
        model_version: data["model_version"],
        target_name: data["target_name"],
        seed: data["seed"],
        runs: deserialize_runs(data["runs"]),
        aggregate_metrics: atomize_keys(data["aggregate_metrics"] || %{})
      }

      {:ok, baseline}
    else
      {:error, :enoent} -> {:error, {:file_not_found, path}}
      {:error, reason} -> {:error, reason}
    end
  end

  # ============================================================================
  # Serialization
  # ============================================================================

  defp encode_baseline(baseline) do
    Jason.encode!(baseline, pretty: true)
  end

  defp decode_baseline(json) do
    case Jason.decode(json) do
      {:ok, data} -> {:ok, data}
      {:error, %Jason.DecodeError{} = error} -> {:error, {:json_decode_error, error}}
    end
  end

  defp serialize_runs(runs) do
    Enum.map(runs, fn run ->
      %{
        commands: Enum.map(run.commands, &serialize_command/1),
        results: Enum.map(run.results, &serialize_result/1),
        timings: run.timings,
        event_log: Enum.map(run.event_log || [], &serialize_event/1),
        is_warmup: Map.get(run, :is_warmup, false)
      }
    end)
  end

  defp deserialize_runs(runs) when is_list(runs) do
    Enum.map(runs, fn run ->
      %{
        commands: Enum.map(run["commands"] || [], &deserialize_command/1),
        results: Enum.map(run["results"] || [], &deserialize_result/1),
        timings: run["timings"] || [],
        event_log: Enum.map(run["event_log"] || [], &deserialize_event/1),
        is_warmup: run["is_warmup"] || false
      }
    end)
  end

  defp deserialize_runs(_), do: []

  defp serialize_command(command) when is_struct(command) do
    %{
      "__struct__" => inspect(command.__struct__),
      "fields" => command |> Map.from_struct() |> serialize_map()
    }
  end

  defp serialize_command(command), do: command

  defp deserialize_command(%{"__struct__" => module_str, "fields" => fields}) do
    # Try to convert the module string to an actual module
    case string_to_module(module_str) do
      {:ok, module} ->
        deserialized_fields =
          fields
          |> deserialize_map()
          |> Enum.map(fn {k, v} -> {String.to_atom(k), v} end)
          |> Map.new()

        struct(module, deserialized_fields)

      :error ->
        # Return as a map with metadata if module doesn't exist
        %{
          __struct_name__: module_str,
          fields: deserialize_map(fields)
        }
    end
  end

  defp deserialize_command(other), do: other

  defp serialize_result({:ok, events}) when is_list(events) do
    %{"status" => "ok", "events" => Enum.map(events, &serialize_event/1)}
  end

  defp serialize_result({:ok, value}) do
    %{"status" => "ok", "value" => serialize_value(value)}
  end

  defp serialize_result({:error, reason}) do
    %{"status" => "error", "reason" => serialize_value(reason)}
  end

  defp serialize_result(other), do: serialize_value(other)

  defp deserialize_result(%{"status" => "ok", "events" => events}) do
    {:ok, Enum.map(events, &deserialize_event/1)}
  end

  defp deserialize_result(%{"status" => "ok", "value" => value}) do
    {:ok, deserialize_value(value)}
  end

  defp deserialize_result(%{"status" => "error", "reason" => reason}) do
    {:error, deserialize_value(reason)}
  end

  defp deserialize_result(other), do: deserialize_value(other)

  defp serialize_event(event) when is_struct(event) do
    %{
      "__struct__" => inspect(event.__struct__),
      "fields" => event |> Map.from_struct() |> serialize_map()
    }
  end

  defp serialize_event(event), do: serialize_value(event)

  defp deserialize_event(%{"__struct__" => module_str, "fields" => fields}) do
    case string_to_module(module_str) do
      {:ok, module} ->
        deserialized_fields =
          fields
          |> deserialize_map()
          |> Enum.map(fn {k, v} -> {String.to_atom(k), v} end)
          |> Map.new()

        struct(module, deserialized_fields)

      :error ->
        %{__struct_name__: module_str, fields: deserialize_map(fields)}
    end
  end

  defp deserialize_event(other), do: deserialize_value(other)

  defp serialize_value(value) when is_struct(value) do
    %{
      "__struct__" => inspect(value.__struct__),
      "fields" => value |> Map.from_struct() |> serialize_map()
    }
  end

  defp serialize_value(value) when is_map(value), do: serialize_map(value)
  defp serialize_value(value) when is_list(value), do: Enum.map(value, &serialize_value/1)

  defp serialize_value(value) when is_tuple(value) do
    %{"__tuple__" => value |> Tuple.to_list() |> Enum.map(&serialize_value/1)}
  end

  defp serialize_value(value) when is_atom(value), do: %{"__atom__" => Atom.to_string(value)}
  defp serialize_value(value) when is_reference(value), do: %{"__ref__" => inspect(value)}
  defp serialize_value(value), do: value

  defp deserialize_value(%{"__struct__" => module_str, "fields" => fields}) do
    case string_to_module(module_str) do
      {:ok, module} ->
        deserialized_fields =
          fields
          |> deserialize_map()
          |> Enum.map(fn {k, v} -> {String.to_atom(k), v} end)
          |> Map.new()

        struct(module, deserialized_fields)

      :error ->
        %{__struct_name__: module_str, fields: deserialize_map(fields)}
    end
  end

  defp deserialize_value(%{"__tuple__" => elements}) do
    elements |> Enum.map(&deserialize_value/1) |> List.to_tuple()
  end

  defp deserialize_value(%{"__atom__" => atom_str}) do
    String.to_atom(atom_str)
  end

  defp deserialize_value(%{"__ref__" => _ref_str}) do
    # References can't be deserialized, return a placeholder
    :deserialized_ref
  end

  defp deserialize_value(map) when is_map(map), do: deserialize_map(map)
  defp deserialize_value(list) when is_list(list), do: Enum.map(list, &deserialize_value/1)
  defp deserialize_value(value), do: value

  defp serialize_map(map) do
    for {k, v} <- map, into: %{} do
      key = if is_atom(k), do: Atom.to_string(k), else: k
      {key, serialize_value(v)}
    end
  end

  defp deserialize_map(map) do
    for {k, v} <- map, into: %{} do
      {k, deserialize_value(v)}
    end
  end

  defp string_to_module(module_str) do
    # Handle both "Elixir.Module.Name" and "Module.Name" formats
    module_str =
      if String.starts_with?(module_str, "Elixir.") do
        module_str
      else
        "Elixir." <> module_str
      end

    try do
      module = String.to_existing_atom(module_str)
      {:ok, module}
    rescue
      ArgumentError -> :error
    end
  end

  defp atomize_keys(map) when is_map(map) do
    for {k, v} <- map, into: %{} do
      key = if is_binary(k), do: String.to_atom(k), else: k
      {key, v}
    end
  end

  defp atomize_keys(other), do: other

  # ============================================================================
  # Helpers
  # ============================================================================

  defp get_model_version(model) do
    # Try to get a version/hash of the model module
    # This helps detect when the model has changed
    try do
      info = model.__info__(:md5)
      Base.encode16(info, case: :lower)
    rescue
      _ -> nil
    end
  end

  defp parse_datetime(iso_string) when is_binary(iso_string) do
    case DateTime.from_iso8601(iso_string) do
      {:ok, datetime, _offset} -> datetime
      {:error, _} -> nil
    end
  end

  defp parse_datetime(_), do: nil

  defp calculate_aggregate_metrics(%{runs: runs}) do
    valid_runs = Enum.filter(runs, fn run -> !Map.get(run, :is_warmup, false) end)

    all_timings =
      valid_runs
      |> Enum.flat_map(& &1.timings)
      |> Enum.sort()

    if all_timings != [] do
      %{
        latency_p50: percentile(all_timings, 50),
        latency_p95: percentile(all_timings, 95),
        latency_p99: percentile(all_timings, 99),
        latency_mean: mean(all_timings),
        latency_min: Enum.min(all_timings),
        latency_max: Enum.max(all_timings),
        total_commands: length(all_timings),
        error_count: count_errors(valid_runs),
        error_rate: error_rate(valid_runs)
      }
    else
      %{}
    end
  end

  defp calculate_aggregate_metrics(_), do: %{}

  defp percentile(sorted_list, p) when sorted_list != [] do
    k = p / 100.0 * (length(sorted_list) - 1)
    f = :erlang.trunc(k)
    c = f + 1

    if c >= length(sorted_list) do
      Enum.at(sorted_list, f)
    else
      d0 = Enum.at(sorted_list, f) * (c - k)
      d1 = Enum.at(sorted_list, c) * (k - f)
      d0 + d1
    end
  end

  defp mean(list) when list != [], do: Enum.sum(list) / length(list)

  defp count_errors(runs) do
    runs
    |> Enum.flat_map(& &1.results)
    |> Enum.count(&match?({:error, _}, &1))
  end

  defp error_rate(runs) do
    total = runs |> Enum.flat_map(& &1.results) |> length()
    if total > 0, do: count_errors(runs) / total, else: 0.0
  end
end
