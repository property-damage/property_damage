defmodule PropertyDamage.RunnerAdapterMsTest do
  # A shrink candidate whose adapter setup fails still spent that time in the
  # adapter, and the oracle's outcome reports it.
  use ExUnit.Case, async: true

  alias PropertyDamage.{Runner, Sequence}
  alias PropertyDamage.Test.Gauntlet, as: G
  alias PropertyDamage.Test.RunnerSupport
  alias PropertyDamage.Test.SetupCommands
  alias PropertyDamage.Test.VariantSupport

  @setup_ms 30

  defmodule SleepyFailingAdapter do
    @moduledoc false
    use PropertyDamage.Adapter

    @impl true
    def setup(_config) do
      Process.sleep(30)
      {:error, :database_unreachable}
    end

    @impl true
    def teardown(_context), do: :ok

    @impl true
    def execute(_command, _context, _runtime), do: {:ok, []}
  end

  defp setup_ms(adapters, model \\ G.Model) do
    sequence = RunnerSupport.plan_for(model, 7, 0, 5)

    plan = %{
      commands: Sequence.to_list(sequence),
      variants: nil,
      setup_commands: sequence.setup,
      teardown_commands: sequence.teardown,
      placeholder_registry: sequence.registry
    }

    context = %Runner.Context{
      model: model,
      targets: RunnerSupport.targets(adapters),
      seed: 7
    }

    outcome = Runner.shrink_oracle(context, nil).(plan, 1)

    assert outcome.status == :setup_failed
    outcome.adapter_ms.setup
  end

  test "the reference target's failed setup is counted in adapter_ms" do
    assert setup_ms([{SleepyFailingAdapter, []}]) >= @setup_ms
  end

  test "a later target's failed setup is counted in adapter_ms" do
    model =
      SetupCommands.define_model!(Module.concat(__MODULE__, SecondTargetModel),
        setup: SetupCommands.standard_setup()
      )

    recorder = VariantSupport.start_recorder()

    targets = [
      SetupCommands.target("a", recorder),
      {SleepyFailingAdapter, name: "b", config: %{}}
    ]

    assert setup_ms(targets, model) >= @setup_ms
  end
end
