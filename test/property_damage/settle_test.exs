defmodule PropertyDamage.SettleTest do
  use ExUnit.Case, async: true

  alias PropertyDamage.Settle

  # Test command modules: static execution/settle metadata lives in command_spec/1
  # (DR-028), authored via `use PropertyDamage.Command, ...`.
  defmodule SyncCommand do
    use PropertyDamage.Command
    defstruct [:id]
    @impl true
    def generator(_overrides \\ %{}), do: StreamData.constant(%{})
  end

  defmodule ProbeCommand do
    use PropertyDamage.Command,
      execution: :probe,
      settle: %{timeout_ms: 500, interval_ms: 50, backoff: :linear}

    defstruct [:id]
    @impl true
    def generator(_overrides \\ %{}), do: StreamData.constant(%{})
  end

  defmodule AsyncCommand do
    use PropertyDamage.Command,
      execution: :async,
      settle: %{timeout_ms: 1000, interval_ms: 100, backoff: :exponential}

    defstruct [:id]
    @impl true
    def generator(_overrides \\ %{}), do: StreamData.constant(%{})
  end

  defmodule NoSemanticsCommand do
    defstruct [:id]
    # No command_spec/1 - should resolve to the framework default (:sync)
  end

  describe "get_semantics/1" do
    test "returns :sync for sync commands" do
      assert Settle.get_semantics(%SyncCommand{id: 1}) == :sync
      assert Settle.get_semantics(SyncCommand) == :sync
    end

    test "returns :probe for probe commands" do
      assert Settle.get_semantics(%ProbeCommand{id: 1}) == :probe
      assert Settle.get_semantics(ProbeCommand) == :probe
    end

    test "returns :async for async commands" do
      assert Settle.get_semantics(%AsyncCommand{id: 1}) == :async
      assert Settle.get_semantics(AsyncCommand) == :async
    end

    test "returns :sync for commands without semantics/0" do
      assert Settle.get_semantics(%NoSemanticsCommand{id: 1}) == :sync
      assert Settle.get_semantics(NoSemanticsCommand) == :sync
    end

    test "returns :sync for plain maps" do
      assert Settle.get_semantics(%{foo: :bar}) == :sync
    end
  end

  describe "get_config/1" do
    test "returns command's settle_config when implemented" do
      config = Settle.get_config(%ProbeCommand{id: 1})

      assert config.timeout_ms == 500
      assert config.interval_ms == 50
      assert config.backoff == :linear
    end

    test "returns defaults when settle_config not implemented" do
      config = Settle.get_config(%SyncCommand{id: 1})

      assert config.timeout_ms == 2_000
      assert config.interval_ms == 300
      assert config.backoff == :linear
    end

    test "works with module directly" do
      config = Settle.get_config(AsyncCommand)

      assert config.timeout_ms == 1000
      assert config.backoff == :exponential
    end
  end

  describe "requires_settling?/1" do
    test "returns true for probes" do
      assert Settle.requires_settling?(%ProbeCommand{id: 1})
    end

    test "returns true for async" do
      assert Settle.requires_settling?(%AsyncCommand{id: 1})
    end

    test "returns false for sync" do
      refute Settle.requires_settling?(%SyncCommand{id: 1})
    end

    test "returns false for commands without semantics" do
      refute Settle.requires_settling?(%NoSemanticsCommand{id: 1})
    end
  end

  describe "settle/2" do
    test "returns immediately on :ok result" do
      result = Settle.settle(fn -> {:ok, :success} end)
      assert result == {:ok, :success}
    end

    test "returns immediately on :settled result" do
      result = Settle.settle(fn -> {:settled, :done} end)
      assert result == {:settled, :done}
    end

    test "returns immediately on :error result" do
      result = Settle.settle(fn -> {:error, :hard_failure} end)
      assert result == {:error, :hard_failure}
    end

    test "retries on :retry until success" do
      # Use agent to track attempts
      {:ok, agent} = Agent.start_link(fn -> 0 end)

      result =
        Settle.settle(
          fn ->
            attempt = Agent.get_and_update(agent, fn n -> {n + 1, n + 1} end)

            if attempt >= 3 do
              {:ok, :success_after_retries}
            else
              {:retry, :not_ready}
            end
          end,
          timeout_ms: 1000,
          interval_ms: 10
        )

      Agent.stop(agent)
      assert result == {:ok, :success_after_retries}
    end

    test "returns timeout when retries exhaust time" do
      result =
        Settle.settle(
          fn -> {:retry, :always_retry} end,
          timeout_ms: 50,
          interval_ms: 10
        )

      assert {:timeout, :always_retry} = result
    end

    test "uses linear backoff by default" do
      sleeps =
        record_sleeps(fn _attempt -> {:retry, :continue} end, timeout_ms: 100, interval_ms: 20)

      # Every sleep but the last stays at the interval; the last is clipped to
      # the time left before the deadline, so it never exceeds the interval.
      assert length(sleeps) >= 2
      {steady, [last]} = Enum.split(sleeps, -1)
      assert Enum.all?(steady, &(&1 == 20))
      assert last in 1..20
    end

    test "uses exponential backoff when specified" do
      sleeps =
        record_sleeps(
          fn attempt -> if attempt < 5, do: {:retry, :continue}, else: {:ok, :done} end,
          timeout_ms: 5_000,
          interval_ms: 10,
          backoff: :exponential
        )

      assert sleeps == [10, 20, 40, 80]
    end

    test "clips the final sleep to the time left before the deadline" do
      sleeps =
        record_sleeps(fn _attempt -> {:retry, :continue} end,
          timeout_ms: 100,
          interval_ms: 40,
          backoff: :linear
        )

      assert hd(sleeps) == 40
      assert List.last(sleeps) < 40
    end

    test "sleeps with the injected :sleep function" do
      parent = self()

      result =
        Settle.settle(fn -> {:retry, :never} end,
          timeout_ms: 30,
          interval_ms: 10,
          sleep: fn ms ->
            send(parent, {:slept, ms})
            Process.sleep(ms)
          end
        )

      assert {:timeout, :never} = result
      assert_received {:slept, 10}
    end

    test "executes the function at least once even with timeout_ms: 0" do
      {:ok, agent} = Agent.start_link(fn -> 0 end)

      result =
        Settle.settle(
          fn ->
            Agent.update(agent, &(&1 + 1))
            {:ok, :ran}
          end,
          timeout_ms: 0
        )

      count = Agent.get(agent, & &1)
      Agent.stop(agent)

      assert result == {:ok, :ran}
      assert count == 1
    end

    test "makes a final attempt at the deadline and reports that attempt's reason" do
      # timeout_ms: 0 means the deadline is reached on entry. The function must
      # still be attempted once (the final attempt at the deadline), and the
      # timeout must carry the reason from that attempt, not a stale nil.
      {:ok, agent} = Agent.start_link(fn -> 0 end)

      result =
        Settle.settle(
          fn ->
            Agent.update(agent, &(&1 + 1))
            {:retry, :still_waiting}
          end,
          timeout_ms: 0
        )

      count = Agent.get(agent, & &1)
      Agent.stop(agent)

      assert count == 1
      assert result == {:timeout, :still_waiting}
    end

    test "does not launder a malformed return into a success" do
      # A function that returns something outside the settle protocol must not
      # be reported as {:ok, _}; that would let a malformed adapter return pass
      # as a successful execution.
      result = Settle.settle(fn -> :some_value end)
      assert result == {:error, {:malformed_settle_return, :some_value}}
    end
  end

  describe "execute_with_settle/3" do
    test "uses settle for probe commands" do
      {:ok, agent} = Agent.start_link(fn -> 0 end)

      result =
        Settle.execute_with_settle(
          %ProbeCommand{id: 1},
          fn ->
            attempt = Agent.get_and_update(agent, fn n -> {n + 1, n + 1} end)

            if attempt >= 2 do
              {:ok, :settled_result}
            else
              {:retry, :waiting}
            end
          end
        )

      Agent.stop(agent)
      assert result == {:ok, :settled_result}
    end

    test "executes directly for sync commands" do
      result =
        Settle.execute_with_settle(
          %SyncCommand{id: 1},
          fn -> {:ok, :direct_result} end
        )

      assert result == {:ok, :direct_result}
    end

    test "uses command's settle_config" do
      # ProbeCommand has timeout_ms: 500, interval_ms: 50
      start = System.monotonic_time(:millisecond)

      result =
        Settle.execute_with_settle(
          %ProbeCommand{id: 1},
          fn -> {:retry, :always} end
        )

      elapsed = System.monotonic_time(:millisecond) - start

      assert {:timeout, :always} = result
      # Should timeout around 500ms (with some buffer)
      assert elapsed >= 400 and elapsed < 700
    end
  end

  # Runs settle with a sleep function that records every requested sleep (and
  # still sleeps, so the deadline advances); `fun` receives the 1-based attempt.
  defp record_sleeps(fun, opts) do
    {:ok, log} = Agent.start_link(fn -> %{sleeps: [], attempts: 0} end)

    Settle.settle(
      fn ->
        attempt =
          Agent.get_and_update(log, fn st ->
            {st.attempts + 1, %{st | attempts: st.attempts + 1}}
          end)

        fun.(attempt)
      end,
      [
        sleep: fn ms ->
          Agent.update(log, fn st -> %{st | sleeps: [ms | st.sleeps]} end)
          Process.sleep(ms)
        end
      ] ++ opts
    )

    sleeps = Agent.get(log, &Enum.reverse(&1.sleeps))
    Agent.stop(log)
    sleeps
  end
end
