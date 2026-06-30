defmodule PropertyDamage.CommandSpecTest do
  use ExUnit.Case, async: true

  alias PropertyDamage.{Command, Model, Settle}

  # Test commands using the new use macro pattern
  defmodule SyncCommand do
    use PropertyDamage.Command

    defstruct [:id]

    @impl true
    def generator(overrides \\ %{}) do
      %{id: StreamData.positive_integer()}
      |> PropertyDamage.Generator.merge_overrides(overrides)
      |> StreamData.fixed_map()
    end
  end

  defmodule ProbeCommand do
    use PropertyDamage.Command,
      execution: :probe,
      shrink: :prefer_remove,
      settle: %{timeout_ms: 5_000, interval_ms: 200, backoff: :exponential}

    defstruct [:id]

    @impl true
    def generator(overrides \\ %{}) do
      %{id: StreamData.positive_integer()}
      |> PropertyDamage.Generator.merge_overrides(overrides)
      |> StreamData.fixed_map()
    end
  end

  defmodule AsyncCommand do
    use PropertyDamage.Command,
      execution: :async,
      shrink: :prefer_keep

    defstruct [:id]

    @impl true
    def generator(overrides \\ %{}) do
      %{id: StreamData.positive_integer()}
      |> PropertyDamage.Generator.merge_overrides(overrides)
      |> StreamData.fixed_map()
    end
  end

  # Spec-less command: implements only the required generator/1 (no command_spec/1).
  # It must resolve to the framework defaults (DR-028: there is no per-callback
  # fallback; a command without command_spec/1 is simply all-defaults).
  defmodule SpeclessCommand do
    @behaviour PropertyDamage.Command

    defstruct [:id]

    @impl true
    def generator(overrides \\ %{}) do
      %{id: StreamData.positive_integer()}
      |> PropertyDamage.Generator.merge_overrides(overrides)
      |> StreamData.fixed_map()
    end
  end

  # Custom command_spec override - doesn't use the macro
  defmodule CustomSpecCommand do
    @behaviour PropertyDamage.Command

    defstruct [:id]

    @impl true
    def generator(overrides \\ %{}) do
      %{id: StreamData.positive_integer()}
      |> PropertyDamage.Generator.merge_overrides(overrides)
      |> StreamData.fixed_map()
    end

    # Implement command_spec directly with custom logic
    @impl true
    def command_spec(overrides \\ []) do
      base =
        Command.framework_defaults()
        |> Map.merge(%{command: __MODULE__, execution: :probe, shrink: :neutral})

      # Apply overrides but ensure weight is at least 2
      result = Map.merge(base, Map.new(overrides))
      %{result | weight: max(result.weight, 2)}
    end
  end

  describe "framework_defaults/0" do
    test "returns default values" do
      defaults = Command.framework_defaults()

      assert defaults.execution == :sync
      assert defaults.settle == %{timeout_ms: 2_000, interval_ms: 300, backoff: :linear}
      assert defaults.shrink == :neutral
      assert is_function(defaults.when, 1)
      assert defaults.when.(%{}) == true
      assert defaults.with == %{}
      assert defaults.weight == 1
      assert defaults.observables == []
      assert defaults.idempotent == true
      assert defaults.acceptable_retry_events == []
    end
  end

  describe "build_spec/3" do
    test "returns spec with command module" do
      spec = Command.build_spec(SyncCommand, [], [])

      assert spec.command == SyncCommand
    end

    test "applies module defaults" do
      spec = Command.build_spec(SyncCommand, [execution: :probe], [])

      assert spec.execution == :probe
    end

    test "overrides take precedence over module defaults" do
      spec = Command.build_spec(SyncCommand, [execution: :probe], execution: :async)

      assert spec.execution == :async
    end

    test "merges all layers" do
      spec =
        Command.build_spec(
          SyncCommand,
          [execution: :probe, weight: 2],
          shrink: :prefer_remove
        )

      # From framework defaults
      assert spec.settle == %{timeout_ms: 2_000, interval_ms: 300, backoff: :linear}
      # From module defaults
      assert spec.execution == :probe
      assert spec.weight == 2
      # From overrides
      assert spec.shrink == :prefer_remove
    end
  end

  describe "use PropertyDamage.Command" do
    test "provides default command_spec/1" do
      spec = SyncCommand.command_spec([])

      assert spec.command == SyncCommand
      assert spec.execution == :sync
      assert spec.shrink == :neutral
      assert spec.weight == 1
    end

    test "allows module-level defaults via use opts" do
      spec = ProbeCommand.command_spec([])

      assert spec.command == ProbeCommand
      assert spec.execution == :probe
      assert spec.shrink == :prefer_remove
      assert spec.settle.timeout_ms == 5_000
      assert spec.settle.interval_ms == 200
      assert spec.settle.backoff == :exponential
    end

    test "allows call-time overrides" do
      spec = SyncCommand.command_spec(weight: 5, execution: :async)

      assert spec.weight == 5
      assert spec.execution == :async
    end

    test "supports custom command_spec override" do
      spec = CustomSpecCommand.command_spec([])

      assert spec.command == CustomSpecCommand
      assert spec.execution == :probe
      # Custom logic enforces minimum weight of 2
      assert spec.weight == 2
    end

    test "custom override respects input but applies custom logic" do
      spec = CustomSpecCommand.command_spec(weight: 1)

      # Custom logic ensures weight is at least 2
      assert spec.weight == 2

      spec2 = CustomSpecCommand.command_spec(weight: 5)
      assert spec2.weight == 5
    end
  end

  describe "Model.normalize_command_spec/1 with command_spec" do
    test "uses command_spec/1 when available" do
      {weight, module, spec} = Model.normalize_command_spec(ProbeCommand)

      assert weight == 1
      assert module == ProbeCommand
      assert spec.execution == :probe
      assert spec.shrink == :prefer_remove
    end

    test "passes opts to command_spec/1" do
      {weight, module, spec} = Model.normalize_command_spec({SyncCommand, weight: 3})

      assert weight == 3
      assert module == SyncCommand
      assert spec.weight == 3
    end

    test "falls back to framework defaults for commands without command_spec" do
      {weight, module, spec} = Model.normalize_command_spec(SpeclessCommand)

      assert weight == 1
      assert module == SpeclessCommand
      assert spec.execution == :sync
      assert spec.shrink == :neutral
    end

    test "handles map form" do
      {weight, module, spec} =
        Model.normalize_command_spec(%{
          command: SyncCommand,
          weight: 4,
          when: fn _ -> false end
        })

      assert weight == 4
      assert module == SyncCommand
      assert spec.weight == 4
      assert spec.when.(%{}) == false
    end
  end

  describe "Model.resolve_spec/2" do
    test "resolves using command_spec when available" do
      spec = Model.resolve_spec(ProbeCommand, [])

      assert spec.command == ProbeCommand
      assert spec.execution == :probe
    end

    test "applies overrides from opts" do
      spec = Model.resolve_spec(SyncCommand, weight: 10, shrink: :prefer_keep)

      assert spec.weight == 10
      assert spec.shrink == :prefer_keep
    end

    test "falls back to framework defaults for spec-less commands" do
      spec = Model.resolve_spec(SpeclessCommand, [])

      assert spec.command == SpeclessCommand
      assert spec.execution == :sync
      assert spec.shrink == :neutral
    end

    test "opts override defaults for spec-less commands" do
      spec = Model.resolve_spec(SpeclessCommand, shrink: :prefer_keep)

      assert spec.shrink == :prefer_keep
    end
  end

  describe "Settle integration" do
    test "get_execution/1 works with spec maps" do
      spec = ProbeCommand.command_spec([])

      assert Settle.get_execution(spec) == :probe
    end

    test "get_settle_config/1 works with spec maps" do
      spec = ProbeCommand.command_spec([])
      config = Settle.get_settle_config(spec)

      assert config.timeout_ms == 5_000
      assert config.interval_ms == 200
      assert config.backoff == :exponential
    end

    test "get_semantics/1 works with spec maps" do
      spec = AsyncCommand.command_spec([])

      assert Settle.get_semantics(spec) == :async
    end

    test "get_config/1 works with spec maps" do
      spec = ProbeCommand.command_spec([])
      config = Settle.get_config(spec)

      assert config.timeout_ms == 5_000
      assert config.interval_ms == 200
    end
  end
end
