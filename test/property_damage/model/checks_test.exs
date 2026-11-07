defmodule PropertyDamage.Model.Projection.ChecksTest do
  use ExUnit.Case, async: true

  alias PropertyDamage.Model.Projection.{Check, Checks}

  defmodule Created do
    defstruct [:n]
  end

  defmodule Mixed do
    use PropertyDamage.Model.Projection

    def init, do: %{}
    def apply(state, _event), do: state

    @check every: 1
    def assert_always(_state, _event), do: :ok

    @check every: 2
    def assert_every_second(_state, _event), do: :ok

    @check every: 1
    def assert_breaks(%{broken: true}, _event), do: {:fail, "broken"}
    def assert_breaks(_state, _event), do: :ok

    @check at: :startup
    def assert_at_start(_state, _phase), do: :ok

    @check at: :teardown
    def assert_at_end(_state, _phase), do: :ok

    @eventually after: Created, timeout: 50, interval: 10
    def assert_settles(_state, _event), do: fn _state -> true end
  end

  defmodule NoChecks do
  end

  defmodule Legacy do
    def __checks__, do: [%{name: :old_shape, trigger: :always}]
  end

  defmodule HandWritten do
    def __checks__ do
      [
        %{
          name: :typed,
          type: :synchronous,
          function_name: :assert_typed,
          trigger: %{type: :every_step}
        }
      ]
    end

    def assert_typed(_state, _event), do: :ok
  end

  @doc false
  def forward(event, measurements, metadata, parent) do
    send(parent, {:telemetry, event, measurements, metadata})
  end

  defp ctx(extra \\ %{}) do
    Map.merge(%{step_type: :event, module: Created, command_or_event: %Created{n: 1}}, extra)
  end

  describe "list/1" do
    test "returns the declared checks as %Check{} structs in declaration order" do
      checks = Checks.list(Mixed)

      assert Enum.all?(checks, &match?(%Check{}, &1))

      assert Enum.map(checks, & &1.name) ==
               [:always, :every_second, :breaks, :at_start, :at_end, :settles]

      assert Enum.map(checks, & &1.kind) == [:step, :step, :step, :phase, :phase, :eventually]
    end

    test "returns [] for a module without a check list" do
      assert Checks.list(NoChecks) == []
      assert Checks.list(Enum) == []
    end

    test "returns a hand-written entry as written" do
      assert Checks.list(Legacy) == [%{name: :old_shape, trigger: :always}]
    end
  end

  describe "phase_checks/2 and eventually_checks/1" do
    test "select by phase and by kind" do
      assert [%{name: :at_start}] = Checks.phase_checks(Mixed, :startup)
      assert [%{name: :at_end}] = Checks.phase_checks(Mixed, :teardown)
      assert [%{name: :settles}] = Checks.eventually_checks(Mixed)
      assert Checks.phase_checks(NoChecks, :startup) == []
    end

    test "a hand-written entry without :type is a model fault naming the projection" do
      assert_raise ArgumentError,
                   ~r/#{inspect(Legacy)}.__checks__\/0 returned an entry without/,
                   fn ->
                     Checks.phase_checks(Legacy, :startup)
                   end
    end

    test "a hand-written entry with :type is read by its derived kind" do
      assert Checks.phase_checks(HandWritten, :startup) == []
      assert {:ok, counters} = Checks.step_checks(HandWritten, %{}, ctx(), %{step: 1})
      assert counters[{:fired, HandWritten, :typed}] == 1
    end
  end

  describe "step_checks/4" do
    test "runs the step checks that fire and counts each firing" do
      assert {:ok, counters} = Checks.step_checks(Mixed, %{}, ctx(), %{step: 1})

      assert counters[{:fired, Mixed, :always}] == 1
      assert counters[{:fired, Mixed, :breaks}] == 1
      refute Map.has_key?(counters, {:fired, Mixed, :at_start})
      refute Map.has_key?(counters, {:fired, Mixed, :settles})
    end

    test "an every: N check fires on the Nth step only" do
      assert {:ok, odd} = Checks.step_checks(Mixed, %{}, ctx(), %{step: 1})
      assert {:ok, even} = Checks.step_checks(Mixed, %{}, ctx(), %{step: 2})

      refute Map.has_key?(odd, {:fired, Mixed, :every_second})
      assert even[{:fired, Mixed, :every_second}] == 1
    end

    test "a step that does not sample skips every: N checks" do
      assert {:ok, counters} =
               Checks.step_checks(Mixed, %{}, ctx(%{sampling: false}), %{step: 2})

      refute Map.has_key?(counters, {:fired, Mixed, :every_second})
      assert counters[{:fired, Mixed, :always}] == 1
    end

    test "the first failing check halts with its name and still counts as fired" do
      assert {:error, :breaks, {exception, stacktrace}, counters} =
               Checks.step_checks(Mixed, %{broken: true}, ctx(), %{step: 1})

      assert is_exception(exception)
      assert is_list(stacktrace)
      assert counters[{:fired, Mixed, :breaks}] == 1
    end

    test "a projection without checks returns the counters unchanged" do
      assert Checks.step_checks(NoChecks, %{}, ctx(), %{step: 1}) == {:ok, %{step: 1}}
    end

    test "emits the check span events when the step context carries telemetry" do
      handler = "checks-test-#{System.unique_integer([:positive])}"
      parent = self()

      :telemetry.attach_many(
        handler,
        [[:property_damage, :check, :start], [:property_damage, :check, :stop]],
        &__MODULE__.forward/4,
        parent
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      telemetry = %{variant: :v, run_number: 1}
      assert {:ok, _} = Checks.step_checks(Mixed, %{}, ctx(%{telemetry: telemetry}), %{step: 1})

      assert_received {:telemetry, [:property_damage, :check, :start], _, %{check_name: :always}}

      assert_received {:telemetry, [:property_damage, :check, :stop], %{duration: _},
                       %{check_name: :always}}
    end
  end
end
