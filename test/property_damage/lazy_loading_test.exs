defmodule PropertyDamage.LazyLoadingTest do
  # Not async: each test unloads a module it compiled itself, and the code
  # path is VM-wide.
  use ExUnit.Case, async: false

  alias PropertyDamage.Model
  alias PropertyDamage.RunTrace
  alias PropertyDamage.Settle
  import PropertyDamage.Test.VariantSupport

  alias PropertyDamage.Test.Lockstep.{Noted, StepAdapter, StepModel}
  alias PropertyDamage.Test.TmpPath

  # Compiles `source` to a .beam in a tmp dir on the code path, then unloads
  # `module`: the module is on disk and loadable, but not loaded, as a user
  # module is the first time a run names it.
  defp compile_unloaded!(module, source) do
    dir = TmpPath.unique("lazy_loading")
    File.mkdir_p!(dir)

    for {mod, binary} <- Code.compile_string(source) do
      File.write!(Path.join(dir, "#{mod}.beam"), binary)
    end

    Code.prepend_path(dir)

    on_exit(fn ->
      Code.delete_path(dir)
      :code.purge(module)
      :code.delete(module)
      File.rm_rf(dir)
    end)

    :code.purge(module)
    :code.delete(module)
    :code.purge(module)
    refute :code.is_loaded(module)
    module
  end

  defp lazy_command(name) do
    module = Module.concat(PropertyDamage.LazyLoadingTest, name)

    compile_unloaded!(module, """
    defmodule #{inspect(module)} do
      def command_spec(opts) do
        PropertyDamage.Command.build_spec(__MODULE__, [execution: :probe, idempotent: false], opts)
      end
    end
    """)
  end

  describe "a command module that is compiled but not loaded" do
    test "Model.resolve_spec/2 keeps its probe and idempotent declarations" do
      module = lazy_command(SpecCommand)

      assert %{execution: :probe, idempotent: false} = Model.resolve_spec(module, [])
    end

    test "Model.normalize_commands/1 keeps its probe declaration (executor and scheduler path)" do
      module = lazy_command(ListedCommand)

      assert [{_weight, ^module, %{execution: :probe, idempotent: false}}] =
               Model.normalize_commands([module])
    end

    test "Settle.get_semantics/1 reads its execution" do
      module = lazy_command(SettledCommand)

      assert Settle.get_semantics(module) == :probe
    end
  end

  describe "an injector module that is compiled but not loaded" do
    test "RunTrace.capture/1 sets it up" do
      module = Module.concat(PropertyDamage.LazyLoadingTest, TraceInjector)

      compile_unloaded!(module, """
      defmodule #{inspect(module)} do
        use PropertyDamage.Adapter.Injector

        @emits [PropertyDamage.Test.Lockstep.Noted]

        @impl true
        def setup(%{event_queue: queue} = config) do
          PropertyDamage.EventQueue.push(queue, __MODULE__, %PropertyDamage.Test.Lockstep.Noted{value: :lazy})
          {:ok, config}
        end

        @impl true
        def teardown(_context), do: :ok

        @impl true
        def to_event(payload), do: {:ok, payload}
      end
      """)

      target = {StepAdapter, name: "solo", config: %{name: "solo"}, injectors: [module]}
      trace = RunTrace.capture(model: StepModel, targets: [target], seed: 1, max_commands: 2)

      assert events_from(trace.event_log, :injector) ==
               [%Noted{value: :lazy}]
    end
  end

  describe "ModuleCheck.exports?/3" do
    test "loads a module that is on disk before asking" do
      module = lazy_command(ProbedCommand)

      assert PropertyDamage.ModuleCheck.exports?(module, :command_spec, 1)
      refute PropertyDamage.ModuleCheck.exports?(module, :no_such_function, 0)
      refute PropertyDamage.ModuleCheck.exports?(PropertyDamage.LazyLoadingTest.NotAModule, :x, 0)
    end
  end
end
