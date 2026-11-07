defmodule PropertyDamage.ShrinkPriorityListingTest do
  @moduledoc """
  An option a model sets on a command's listing in `commands/0` (here
  `shrink: :prefer_keep`) applies when the shrinker orders its removals, not
  only when the command runs.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Mix.Tasks.Pd.Validate

  alias PropertyDamage.{FailureReport, Sequence}

  defmodule Done do
    defstruct []
  end

  defmodule Keep do
    use PropertyDamage.Command
    defstruct []
    @impl true
    def generator(_overrides \\ %{}), do: StreamData.constant(%{})
  end

  defmodule Plain do
    use PropertyDamage.Command
    defstruct []
    @impl true
    def generator(_overrides \\ %{}), do: StreamData.constant(%{})
  end

  defmodule Count do
    use PropertyDamage.Model.Projection

    @impl true
    def init, do: 0
    @impl true
    def apply(count, %Done{}), do: count + 1
    def apply(count, _event), do: count

    # Fails for any sequence of two or more commands, whatever they are.
    @check at: :teardown
    def at_most_one(count, _step), do: count < 2
  end

  defmodule Adapter do
    use PropertyDamage.Adapter

    @impl true
    def setup(config), do: {:ok, config}
    @impl true
    def execute(_command, _ctx, _runtime), do: {:ok, [%Done{}]}
    @impl true
    def teardown(_ctx), do: :ok
  end

  defmodule ListedModel do
    use PropertyDamage.Model
    @impl true
    def commands, do: [{Keep, shrink: :prefer_keep, weight: 1}, {Plain, weight: 15}]

    @impl true
    def command_sequence_projection, do: Count
    @impl true
    def check_projections, do: [Count]
  end

  defmodule UnlistedModel do
    use PropertyDamage.Model
    @impl true
    def commands, do: [{Keep, weight: 1}, {Plain, weight: 15}]
    @impl true
    def command_sequence_projection, do: Count
    @impl true
    def check_projections, do: [Count]
  end

  defmodule TwiceModel do
    use PropertyDamage.Model
    @impl true
    def commands, do: [{Keep, shrink: :prefer_keep}, Plain, {Keep, weight: 3}]
    @impl true
    def command_sequence_projection, do: Count
    @impl true
    def check_projections, do: [Count]
  end

  @seed 7

  defp run_failing(model) do
    PropertyDamage.run(
      model: model,
      targets: [Adapter],
      seed: @seed,
      max_commands: 8,
      max_runs: 1,
      validate: false,
      verbose: false
    )
  end

  defp shrunk(model) do
    assert {:error, failure} = run_failing(model)

    {failure.original_sequence |> Sequence.to_list(),
     FailureReport.shrunk_sequence(failure) |> Sequence.to_list()}
  end

  test "a listed shrink: :prefer_keep keeps the command in the shrunk reproduction" do
    {original, shrunk} = shrunk(ListedModel)

    assert [%Keep{} | rest] = original
    assert length(rest) >= 2 and Enum.all?(rest, &match?(%Plain{}, &1))
    assert [%Keep{}, %Plain{}] = shrunk
  end

  test "the same command listed without the option is shrunk away first (control)" do
    {original, shrunk} = shrunk(UnlistedModel)

    assert [%Keep{} | _] = original
    refute Enum.any?(shrunk, &match?(%Keep{}, &1))
    assert length(shrunk) == 2
  end

  describe "a module listed twice in commands/0" do
    test "run/1 rejects it, naming the module and both listings" do
      assert_raise ArgumentError, ~r/Keep.*shrink: :prefer_keep.*weight: 3.*one entry/s, fn ->
        run_failing(TwiceModel)
      end
    end

    test "Model.spec_table/1 rejects it with the same message" do
      error = assert_raise ArgumentError, fn -> PropertyDamage.Model.spec_table(TwiceModel) end
      assert error.message =~ inspect(Keep)
      assert error.message =~ "{#{inspect(Keep)}, [shrink: :prefer_keep]}"
      assert error.message =~ "{#{inspect(Keep)}, [weight: 3]}"
    end

    test "mix pd.validate reports it as an error, with and without an adapter" do
      model = inspect(TwiceModel)

      for args <- [[model], [model, inspect(Adapter)]] do
        output =
          capture_io(fn ->
            send(self(), {:status, Validate.exec(args)})
          end)

        assert_received {:status, :error}
        assert output =~ "{#{inspect(Keep)}, [shrink: :prefer_keep]}"
        assert output =~ "{#{inspect(Keep)}, [weight: 3]}"
      end
    end
  end
end
