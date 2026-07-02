defmodule PropertyDamage.Runtime.InjectionWindowTest do
  use ExUnit.Case, async: true

  alias PropertyDamage.Runtime
  alias PropertyDamage.Runtime.InjectionWindow
  alias PropertyDamage.Runtime.Sink

  # A lean build_runtime mirroring the differential/load-test paths: inject
  # accumulates raw events (newest-first) into %{events: []}; start_poller raises.
  defp lean_build_runtime do
    fn sink ->
      %Runtime{
        inject: fn event ->
          Sink.update_ctx(sink, fn ctx -> %{ctx | events: [event | ctx.events]} end)
        end,
        start_poller: fn _opts -> raise ArgumentError, "no pollers here" end
      }
    end
  end

  test "returns {result, final_ctx, pollers} from a clean execution" do
    {result, final_ctx, pollers} =
      InjectionWindow.run(%{events: []}, lean_build_runtime(), fn _rt -> {:ok, [:e1]} end)

    assert result == {:ok, [:e1]}
    assert final_ctx == %{events: []}
    assert pollers == []
  end

  test "injected events accumulate into the sink context in injection order" do
    {result, final_ctx, _pollers} =
      InjectionWindow.run(%{events: []}, lean_build_runtime(), fn rt ->
        rt.inject.(:first)
        rt.inject.(:second)
        {:ok, [:returned]}
      end)

    assert result == {:ok, [:returned]}
    # Accumulated newest-first; callers reverse to injection order.
    assert final_ctx.events == [:second, :first]
    assert Enum.reverse(final_ctx.events) == [:first, :second]
  end

  test "returns pollers registered during execution" do
    build_runtime = fn sink ->
      %Runtime{
        inject: fn _ -> :ok end,
        start_poller: fn opts ->
          Sink.add_poller(sink, opts)
          opts
        end
      }
    end

    {_result, _ctx, pollers} =
      InjectionWindow.run(%{events: []}, build_runtime, fn rt ->
        rt.start_poller.(:poller_a)
        {:ok, []}
      end)

    assert pollers == [:poller_a]
  end

  test "stops the sink even when execute_fn raises, then re-raises" do
    test_pid = self()

    build_runtime = fn sink ->
      send(test_pid, {:sink, sink})
      %Runtime{inject: fn _ -> :ok end, start_poller: fn _ -> :ok end}
    end

    assert_raise RuntimeError, "boom", fn ->
      InjectionWindow.run(%{events: []}, build_runtime, fn _rt -> raise "boom" end)
    end

    assert_received {:sink, sink}
    refute Process.alive?(sink), "the sink Agent must be stopped even on a raise"
  end

  test "stops the sink after a clean execution" do
    test_pid = self()

    build_runtime = fn sink ->
      send(test_pid, {:sink, sink})
      %Runtime{inject: fn _ -> :ok end, start_poller: fn _ -> :ok end}
    end

    InjectionWindow.run(%{events: []}, build_runtime, fn _rt -> {:ok, []} end)

    assert_received {:sink, sink}
    refute Process.alive?(sink)
  end

  describe "run_accumulating/2" do
    test "returns {result, injected_events} with injected events in injection order" do
      {result, injected} =
        InjectionWindow.run_accumulating(
          fn rt ->
            rt.inject.(:a)
            rt.inject.(:b)
            {:ok, [:returned]}
          end,
          "no pollers"
        )

      assert result == {:ok, [:returned]}
      assert injected == [:a, :b]
    end

    test "start_poller raises with the supplied message" do
      assert_raise ArgumentError, "custom poller error", fn ->
        InjectionWindow.run_accumulating(
          fn rt -> rt.start_poller.([]) end,
          "custom poller error"
        )
      end
    end
  end
end
