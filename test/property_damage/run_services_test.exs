defmodule PropertyDamage.Runtime.RunServicesTest do
  # The per-run wiring of a target's injectors and mocks: whatever a later
  # setup does, the injectors already set up are torn down again.
  use ExUnit.Case, async: true

  alias PropertyDamage.Runtime.RunServices
  alias PropertyDamage.Test.RecordingInjector

  defmodule RaisingInjector do
    @moduledoc false
    use PropertyDamage.Adapter.Injector

    @emits []

    @impl true
    def setup(_config), do: raise("listener refused")

    @impl true
    def teardown(_context), do: :ok

    @impl true
    def to_event(_payload), do: :skip
  end

  defmodule RaisingMock do
    @moduledoc false
    use PropertyDamage.MockServiceAdapter

    @impl true
    def init_state, do: %{}

    @impl true
    def setup(_config), do: raise("mock refused")
  end

  defp target(injectors, mocks \\ []) do
    %{injectors: injectors, mocks: mocks, config: %{test_pid: self()}}
  end

  test "an injector setup that raises tears down the injectors set up before it" do
    result =
      RunServices.with_services(target([RecordingInjector, RaisingInjector]), fn _queue, _mocks ->
        flunk("the run body must not run when a setup failed")
      end)

    assert {:error, %RuntimeError{message: "listener refused"}} = result
    assert_received {:injector_setup, _config, context}
    assert_received {:injector_teardown, ^context}
  end

  test "a mock setup that raises tears the injectors down" do
    assert_raise RuntimeError, "mock refused", fn ->
      RunServices.with_services(target([RecordingInjector], [{RaisingMock, %{}}]), fn _q, _m ->
        flunk("the run body must not run when a setup failed")
      end)
    end

    assert_received {:injector_setup, _config, context}
    assert_received {:injector_teardown, ^context}
  end
end
