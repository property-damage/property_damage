defmodule PropertyDamage.SetupCommandsReportTest do
  # What a reader sees of setup and teardown commands: the command telemetry
  # names each command's phase, the verbose printer and the report formatter
  # locate a setup failure at its setup command, coverage counts setup
  # commands apart from the roots, and the exported scripts run the setup
  # commands before the roots (wiring the ids they produce into the roots) and
  # the teardown commands after them.
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias PropertyDamage.{Coverage, Export, FailureReport}
  alias PropertyDamage.Export.HTTPSpec
  alias PropertyDamage.FailureReport.Formatter
  alias PropertyDamage.Progress.Printer
  alias PropertyDamage.Test.SetupCommands
  alias PropertyDamage.Test.SetupCommands.{Act, Cleanup, CreateUser, Login, Tick}

  defmodule LoginSeen do
    # A passing check on every Login: its fires come from setup steps.
    use PropertyDamage.Model.Projection

    @impl true
    def init, do: %{}

    @impl true
    def apply(state, _), do: state

    @check every: PropertyDamage.Test.SetupCommands.Login
    def assert_login_seen(_state, _login), do: :ok
  end

  defmodule SecondActFails do
    # Fails on the event of the Act whose `n` is 1 (the second Act root).
    use PropertyDamage.Model.Projection

    @impl true
    def init, do: %{}

    @impl true
    def apply(state, _), do: state

    @check every: PropertyDamage.Test.SetupCommands.Acted
    def assert_not_second_act(_state, %{n: n}) do
      if n == 1, do: PropertyDamage.fail!("the second act"), else: :ok
    end
  end

  defmodule HttpAdapter do
    # The fixture adapter with an HTTP mapping for every command.
    use PropertyDamage.Adapter

    alias PropertyDamage.Test.SetupCommands.{Act, Cleanup, CreateUser, FixtureAdapter, Login}

    @impl true
    def setup(config), do: FixtureAdapter.setup(config)

    @impl true
    def teardown(ctx), do: FixtureAdapter.teardown(ctx)

    @impl true
    def execute(command, ctx, runtime), do: FixtureAdapter.execute(command, ctx, runtime)

    def http_spec(%CreateUser{name: name}, _ctx),
      do: %HTTPSpec{method: :post, path: "/users", body: %{name: name}}

    def http_spec(%Login{user_id: user_id}, _ctx),
      do: %HTTPSpec{method: :post, path: "/login", body: %{user_id: user_id}}

    def http_spec(%Act{n: n, user_id: user_id}, _ctx),
      do: %HTTPSpec{method: :post, path: "/acts", body: %{n: n, user_id: user_id}}

    def http_spec(%Cleanup{thing_id: thing_id}, _ctx),
      do: %HTTPSpec{
        method: :delete,
        path: "/things/:thing_id",
        path_params: %{thing_id: thing_id}
      }
  end

  @max_commands 6

  defp model!(name, opts), do: SetupCommands.define_model!(Module.concat(__MODULE__, name), opts)

  # The model `name`, defined on first use.
  defp model_once!(name, opts) do
    module = Module.concat(__MODULE__, name)
    if Code.ensure_loaded?(module), do: module, else: model!(name, opts)
  end

  defp run(model, targets, extra) do
    PropertyDamage.run(
      Keyword.merge(
        [
          model: model,
          targets: targets,
          max_runs: 1,
          max_commands: @max_commands,
          validate: false
        ],
        extra
      )
    )
  end

  defp setup_failure_report(name, config, setup \\ SetupCommands.standard_setup()) do
    model =
      model!(name,
        commands: [Tick],
        checks: [],
        setup: setup,
        teardown: [Cleanup]
      )

    target = {SetupCommands.FixtureAdapter, name: "a", config: Map.merge(%{name: "a"}, config)}
    assert {:error, %FailureReport{kind: :setup_failed} = report} = run(model, [target], seed: 3)
    report
  end

  # ==========================================================================
  # Telemetry
  # ==========================================================================

  describe "command telemetry" do
    test "names the phase of every setup, root and teardown command" do
      test_pid = self()
      handler = "setup-commands-phase-#{System.unique_integer([:positive])}"

      :telemetry.attach_many(
        handler,
        [[:property_damage, :command, :start], [:property_damage, :command, :stop]],
        fn [_, _, event], _measurements, metadata, _config ->
          if metadata.variant.name == "phases",
            do:
              send(test_pid, {:command, event, metadata.command, metadata.phase, metadata.index})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      model =
        model!(Telemetry,
          commands: [Tick],
          checks: [],
          setup: SetupCommands.standard_setup(),
          teardown: [Cleanup]
        )

      target = {SetupCommands.FixtureAdapter, name: "phases", config: %{name: "phases"}}
      assert {:ok, _stats} = run(model, [target], seed: 3)

      events = take_commands([])
      roots = for {:command, :start, Tick, :root, index} <- events, do: index

      assert [
               {:command, :start, CreateUser, :setup, 0},
               {:command, :stop, CreateUser, :setup, 0},
               {:command, :start, Login, :setup, 1},
               {:command, :stop, Login, :setup, 1}
               | _
             ] = events

      assert roots == Enum.to_list(0..(length(roots) - 1))
      assert roots != []

      assert Enum.take(events, -2) == [
               {:command, :start, Cleanup, :teardown, 0},
               {:command, :stop, Cleanup, :teardown, 0}
             ]
    end
  end

  defp take_commands(acc) do
    receive do
      {:command, _, _, _, _} = message -> take_commands([message | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # ==========================================================================
  # Printer and formatter
  # ==========================================================================

  describe "a setup failure in the printer and the formatter" do
    test "is located at its setup command, with the cause" do
      report = setup_failure_report(CommandFailed, %{fail: %{Login => :error}})

      printed = capture_io(fn -> Printer.print_failure(report) end)

      assert printed =~
               "Failed at:    setup command 1 (PropertyDamage.Test.SetupCommands.Login), cause: command"

      refute printed =~ "not localized"

      formatted = Formatter.format(report, :terminal, color: false)

      assert formatted =~
               "setup command 1 (PropertyDamage.Test.SetupCommands.Login), cause: command"

      markdown = Formatter.format(report, :markdown)

      assert markdown =~
               "setup command 1 (PropertyDamage.Test.SetupCommands.Login), cause: command"
    end

    test "names the field of an unresolved placeholder" do
      # Nothing consumes the id, so only the completion rule notices it.
      report =
        setup_failure_report(Unresolved, %{drop_id: true}, [
          {CreateUser, overrides: %{name: "fixture"}}
        ])

      printed = capture_io(fn -> Printer.print_failure(report) end)

      assert printed =~
               "setup command 0 (PropertyDamage.Test.SetupCommands.CreateUser), " <>
                 "cause: unresolved_placeholder, field [:id]"
    end
  end

  # ==========================================================================
  # Coverage
  # ==========================================================================

  describe "coverage" do
    test "counts the setup commands under setup, never as roots, and counts check fires on them" do
      model =
        model!(Coverage,
          commands: [Tick],
          checks: [LoginSeen],
          setup: SetupCommands.standard_setup(),
          teardown: [Cleanup]
        )

      target = {SetupCommands.FixtureAdapter, name: "a", config: %{name: "a"}}
      assert {:ok, stats} = run(model, [target], seed: 3, max_runs: 3, coverage: true)

      summary = Coverage.stats(stats.coverage)
      assert summary.setup == %{CreateUser => 3, Login => 3}

      refute Map.has_key?(stats.coverage.command_counts, CreateUser)
      refute Map.has_key?(stats.coverage.command_counts, Login)
      refute Map.has_key?(stats.coverage.command_counts, Cleanup)

      refute Enum.any?(Map.keys(stats.coverage.transition_counts), fn {from, to} ->
               from in [CreateUser, Login] or to in [CreateUser, Login]
             end)

      assert stats.check_fires[{LoginSeen, :login_seen}] == 3
    end
  end

  # ==========================================================================
  # Export
  # ==========================================================================

  describe "exported scripts" do
    setup do
      model =
        model_once!(ExportModel,
          commands: SetupCommands.act_roots(),
          checks: [SecondActFails],
          setup: SetupCommands.standard_setup(),
          teardown: [{Cleanup, overrides: fn state -> %{thing_id: state.user} end}]
        )

      target = {HttpAdapter, name: "a", config: %{name: "a"}}

      assert {:error, %FailureReport{kind: :check_failed} = report} =
               run(model, [target], seed: 1, shrink: false)

      {:ok, report: report}
    end

    test "a curl script runs the setup steps first, wires their id into the roots and ends with the teardown step",
         %{report: report} do
      script =
        Export.to_script(report, :curl, base_url: "http://localhost:4000", adapter: HttpAdapter)

      setup_1 = position!(script, "=== Setup step 1 (setup position 0): CreateUser ===")
      setup_2 = position!(script, "=== Setup step 2 (setup position 1): Login ===")
      first_root = position!(script, "=== Step 1: Act ===")
      last_root = position!(script, "=== Step #{root_count(report)}: Act")
      teardown = position!(script, "=== Teardown step 1 (teardown position 0): Cleanup ===")
      footer = position!(script, "=== Reproduction Complete ===")

      assert setup_1 < setup_2 and setup_2 < first_root
      assert last_root < teardown and teardown < footer

      # The CreateUser setup step binds the id it produces; Login, the roots and
      # the teardown step read it.
      binding =
        position!(
          script,
          ~s|usercreated_id_setup0=$(echo "$RESP_setup_1" \| jq -r '.id // empty')|
        )

      assert setup_1 < binding and binding < setup_2
      assert script =~ ~s|\\"user_id\\":$usercreated_id_setup0|
      assert after_position(script, first_root) =~ "$usercreated_id_setup0"
      assert after_position(script, teardown) =~ ~s|"$BASE_URL/things/$usercreated_id_setup0"|
    end

    test "an Elixir script runs the setup steps first and wires their id into the roots",
         %{report: report} do
      script =
        Export.to_script(report, :elixir, base_url: "http://localhost:4000", adapter: HttpAdapter)

      setup_1 = position!(script, "=== Setup step 1 (setup position 0): CreateUser ===")
      first_root = position!(script, "=== Step 1: Act ===")
      teardown = position!(script, "=== Teardown step 1 (teardown position 0): Cleanup ===")

      assert setup_1 < first_root and first_root < teardown

      binding = position!(script, ~s|"usercreated_id_setup0"|)
      assert binding < first_root
      assert after_position(script, first_root) =~ ~s|refs["usercreated_id_setup0"]|
    end

    test "the ExUnit export lists the setup commands in a comment", %{report: report} do
      code = Export.to_exunit(report)

      comment = position!(code, "# Setup commands, run before the roots:")
      commands = position!(code, "_commands = [")
      assert comment < commands
      assert code =~ "#   %PropertyDamage.Test.SetupCommands.CreateUser{"
    end
  end

  defp root_count(report),
    do: report |> FailureReport.shrunk_sequence() |> PropertyDamage.Sequence.command_count()

  defp position!(text, fragment) do
    case :binary.match(text, fragment) do
      {position, _length} -> position
      :nomatch -> flunk("#{inspect(fragment)} not found in:\n#{text}")
    end
  end

  defp after_position(text, position), do: binary_part(text, position, byte_size(text) - position)
end
