defmodule PropertyDamage.SetupFailureTest do
  # A setup failure (`kind: :setup_failed`) follows the rule an execution
  # failure follows: in the reference it ends the run before root 0; in
  # another target it retires that target, which runs its teardown commands
  # and `Adapter.teardown/1` before any target starts root 0, and the others
  # go on while a target other than the reference is left.
  use ExUnit.Case, async: true

  import PropertyDamage.Test.VariantSupport

  alias PropertyDamage.{Failure, FailureReport}
  alias PropertyDamage.Test.SetupCommands
  alias PropertyDamage.Test.SetupCommands.{Act, Cleanup, CreateUser, Login}

  # When set, the three-target order test writes its recorded order here.
  @order_log_env "PD_SETUP_ORDER_LOG"

  defp model!(name) do
    SetupCommands.define_model!(Module.concat(__MODULE__, name),
      setup: SetupCommands.standard_setup(),
      teardown: [{Cleanup, overrides: %{thing_id: "fixture"}}]
    )
  end

  defp run(model, targets, extra \\ []) do
    PropertyDamage.run(
      Keyword.merge(
        [
          model: model,
          targets: targets,
          compare: [converge_within: 30],
          max_runs: 1,
          max_commands: 3,
          seed: 77,
          validate: false
        ],
        extra
      )
    )
  end

  # Each setup command executed at least once in `name`.
  defp assert_setup_ran(entries, name) do
    executed = SetupCommands.executed(entries, name)
    assert Enum.any?(executed, &match?(%CreateUser{}, &1))
    assert Enum.any?(executed, &match?(%Login{}, &1))
  end

  defp roots(entries, name), do: for({:execute, ^name, %Act{}} <- entries, do: :root)

  defp torn_down?(entries, name) do
    mine = SetupCommands.of(entries, name)
    cleanup = SetupCommands.position(mine, &match?({:execute, _, %Cleanup{}}, &1))
    teardown = SetupCommands.position(mine, &(&1 == {:teardown, name}))
    is_integer(cleanup) and is_integer(teardown) and cleanup < teardown
  end

  describe "two targets" do
    test "setup/1 failing in variant 1 tears the reference down; no root runs" do
      recorder = start_recorder()

      assert {:error, %FailureReport{} = report} =
               run(model!(AdapterSetupTwo), [
                 SetupCommands.target("a", recorder),
                 SetupCommands.target("b", recorder, %{fail_setup: true})
               ])

      assert report.kind == :setup_failed
      assert report.variant == %{index: 1, name: "b"}
      assert report.failed_at_index == nil
      assert report.shrink_iterations == 0

      assert %Failure{type: %Failure.Setup{cause: :adapter_setup, detail: :no_backend}} =
               report.failure_reason

      entries = recorded(recorder)
      assert torn_down?(entries, "a")
      # No adapter context in b: nothing to tear down.
      refute {:teardown, "b"} in entries
      assert roots(entries, "a") == [] and roots(entries, "b") == []
    end

    test "a setup command error in variant 1 names the command and its index" do
      recorder = start_recorder()

      assert {:error, %FailureReport{} = report} =
               run(model!(CommandErrorTwo), [
                 SetupCommands.target("a", recorder),
                 SetupCommands.target("b", recorder, %{fail: %{Login => :error}})
               ])

      assert report.kind == :setup_failed
      assert report.variant == %{index: 1, name: "b"}
      assert report.failed_at_index == nil

      assert %Failure{
               type: %Failure.Setup{
                 cause: :command,
                 setup_index: 1,
                 command: %Login{},
                 detail: {:refused, Login}
               }
             } = report.failure_reason

      assert FailureReport.failure_message(report) =~ "Login"

      entries = recorded(recorder)
      assert_setup_ran(entries, "a")
      assert torn_down?(entries, "a")
      assert torn_down?(entries, "b")
      assert roots(entries, "a") == [] and roots(entries, "b") == []
    end

    test "a setup command failing in the reference ends the run; every variant tears down" do
      recorder = start_recorder()

      assert {:error, %FailureReport{} = report} =
               run(model!(ReferenceCommand), [
                 SetupCommands.target("a", recorder, %{fail: %{CreateUser => :raise}}),
                 SetupCommands.target("b", recorder)
               ])

      assert report.kind == :setup_failed
      assert report.variant == %{index: 0, name: "a"}

      assert %Failure{type: %Failure.Setup{cause: :command, setup_index: 0}} =
               report.failure_reason

      entries = recorded(recorder)
      assert torn_down?(entries, "a")
      assert torn_down?(entries, "b")
      assert roots(entries, "a") == [] and roots(entries, "b") == []
    end
  end

  describe "three targets" do
    for concurrency <- [:serial, :parallel] do
      test "a setup command error in variant 2 retires it before root 0 (#{concurrency})" do
        recorder = start_recorder()

        assert {:error, %FailureReport{} = report} =
                 run(
                   model!(Module.concat(CommandErrorThree, unquote(concurrency))),
                   [
                     SetupCommands.target("a", recorder),
                     SetupCommands.target("b", recorder),
                     SetupCommands.target("c", recorder, %{fail: %{Login => :error}})
                   ],
                   concurrency: unquote(concurrency)
                 )

        assert report.kind == :setup_failed
        assert report.variant == %{index: 2, name: "c"}
        assert report.other_failures == []

        entries = recorded(recorder)
        if unquote(concurrency) == :serial, do: maybe_save_order(entries)

        # c tore down before root 0 started anywhere.
        c_teardown = SetupCommands.position(entries, &(&1 == {:teardown, "c"}))
        first_root = SetupCommands.position(entries, &match?({:execute, _, %Act{}}, &1))
        assert torn_down?(entries, "c")
        assert c_teardown < first_root

        assert_setup_ran(entries, "a")
        assert_setup_ran(entries, "b")

        # a and b ran to the end.
        assert length(roots(entries, "a")) == 3
        assert length(roots(entries, "b")) == 3
        assert roots(entries, "c") == []
        assert torn_down?(entries, "a")
        assert torn_down?(entries, "b")
      end
    end

    test "setup/1 failing in variant 2 lets variants 0 and 1 run to the end" do
      recorder = start_recorder()

      assert {:error, %FailureReport{} = report} =
               run(model!(AdapterSetupThree), [
                 SetupCommands.target("a", recorder),
                 SetupCommands.target("b", recorder),
                 SetupCommands.target("c", recorder, %{fail_setup: true})
               ])

      assert report.kind == :setup_failed
      assert report.variant == %{index: 2, name: "c"}
      assert report.other_failures == []

      entries = recorded(recorder)
      assert_setup_ran(entries, "a")
      assert length(roots(entries, "a")) == 3
      assert length(roots(entries, "b")) == 3
      refute {:teardown, "c"} in entries
      assert torn_down?(entries, "a")
      assert torn_down?(entries, "b")
    end
  end

  defp maybe_save_order(entries) do
    case System.get_env(@order_log_env) do
      nil ->
        :ok

      path ->
        lines =
          Enum.map(entries, fn
            {:execute, name, command} -> "execute #{name} #{inspect(command)}"
            other -> other |> Tuple.to_list() |> Enum.map_join(" ", &to_string_entry/1)
          end)

        File.write!(path, Enum.join(lines, "\n") <> "\n")
    end
  end

  defp to_string_entry(value) when is_binary(value), do: value
  defp to_string_entry(value), do: inspect(value)
end
