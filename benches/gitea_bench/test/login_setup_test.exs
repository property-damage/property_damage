defmodule LoginSetupTest do
  @moduledoc """
  The model's `Login` setup command on both transports: every run, in every
  target, opens the admin's session once before the roots, and a target whose
  login fails is a setup failure that executes none of its roots.
  """

  use ExUnit.Case, async: false

  alias GiteaBench.Commands.Login
  alias PropertyDamage.{Failure, FailureReport}

  @api_url Application.compile_env(:gitea_bench, :api_url)
  @ui_url Application.compile_env(:gitea_bench, :ui_url)
  @admin_user Application.compile_env(:gitea_bench, :admin_user)
  @admin_password Application.compile_env(:gitea_bench, :admin_password)

  defmodule TrackedApiAdapter do
    @moduledoc false
    # The API adapter, reporting its teardown/1 to the test.
    use PropertyDamage.Adapter

    @impl true
    def setup(config) do
      {:ok, ctx} = GiteaBench.ApiAdapter.setup(config)
      {:ok, Map.put(ctx, :test_pid, config.test_pid)}
    end

    @impl true
    def teardown(ctx) do
      send(ctx.test_pid, {:torn_down, "api"})
      GiteaBench.ApiAdapter.teardown(ctx)
    end

    @impl true
    def execute(command, ctx, runtime), do: GiteaBench.ApiAdapter.execute(command, ctx, runtime)
  end

  defp api_config,
    do: %{base_url: @api_url, admin_user: @admin_user, admin_password: @admin_password}

  defp ui_config(extra \\ %{}),
    do:
      Map.merge(
        %{base_url: @ui_url, admin_user: @admin_user, admin_password: @admin_password},
        extra
      )

  # Sends every command start the engine emits to the test, as
  # `{:command, variant_name, phase, module}`.
  defp attach_command_events do
    test_pid = self()
    handler = "gitea-login-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:property_damage, :command, :start],
      fn _event, _measurements, metadata, _config ->
        send(test_pid, {:command, metadata.variant.name, metadata.phase, metadata.command})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  defp commands_started(acc \\ []) do
    receive do
      {:command, _name, _phase, _module} = message -> commands_started([message | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp count(events, name, phase, module \\ nil) do
    Enum.count(events, fn {:command, n, p, m} ->
      n == name and p == phase and (module == nil or m == module)
    end)
  end

  @tag timeout: 600_000
  test "both transports log in exactly once per run, before the roots" do
    attach_command_events()

    assert {:ok, stats} =
             PropertyDamage.run(
               model: GiteaBench.Model,
               targets: [
                 {GiteaBench.ApiAdapter, name: "api", config: api_config()},
                 {GiteaBench.UiAdapter, name: "ui", config: ui_config()}
               ],
               max_commands: 6,
               max_runs: 2,
               seed: 1
             )

    events = commands_started()
    assert stats.setup_commands == 2

    for name <- ["api", "ui"] do
      assert count(events, name, :setup, Login) == 2
      assert count(events, name, :setup) == 2
      assert count(events, name, :root) > 0
    end
  end

  @tag timeout: 600_000
  test "a wrong login password on the ui target is a setup failure of its Login" do
    attach_command_events()

    assert {:error, %FailureReport{} = report} =
             PropertyDamage.run(
               model: GiteaBench.Model,
               targets: [
                 {TrackedApiAdapter,
                  name: "api", config: Map.put(api_config(), :test_pid, self())},
                 {GiteaBench.UiAdapter,
                  name: "ui", config: ui_config(%{login_password: "not-the-password"})}
               ],
               max_commands: 6,
               max_runs: 1,
               seed: 1
             )

    assert report.kind == :setup_failed
    assert report.variant == %{index: 1, name: "ui"}
    assert report.failed_at_index == nil

    assert %Failure{type: %Failure.Setup{cause: :command, setup_index: 0, command: %Login{}}} =
             report.failure_reason

    assert {:login_failed, _reason} = Failure.detail(report.failure_reason)

    events = commands_started()
    assert count(events, "ui", :setup, Login) == 1
    assert count(events, "ui", :root) == 0

    # The reference was torn down.
    assert_received {:torn_down, "api"}
  end
end
