defmodule PropertyDamage.MockCallbackFailureTest do
  # A mock's on_command/2 or on_event/2 that raises fails the step it ran for,
  # as an adapter error naming the mock and the callback, the shape a raising
  # adapter execute/3 gets. A projection that rejects a mock event keeps the
  # lines the mock's on_event/2 wrote under that step (DR-054).
  use ExUnit.Case, async: false

  alias PropertyDamage.Test.LogFixtures, as: F
  alias PropertyDamage.Test.LogPathFixtures, as: P

  defmodule CommandRaisingMock do
    @moduledoc false
    use PropertyDamage.MockServiceAdapter

    @emits []

    @impl true
    def setup(_config), do: {:ok, %{}}

    @impl true
    def teardown(_context), do: :ok

    @impl true
    def init_state, do: %{}

    @impl true
    def on_command(%{n: 1}, _state), do: raise("mock refused act 1")
    def on_command(_command, state), do: state

    @impl true
    def on_event(_event, state), do: state

    @impl true
    def handle_request(_request, state), do: {:ok, %{status: 200}, state}
  end

  defmodule EventRaisingMock do
    @moduledoc false
    use PropertyDamage.MockServiceAdapter

    @emits []

    @impl true
    def setup(_config), do: {:ok, %{}}

    @impl true
    def teardown(_context), do: :ok

    @impl true
    def init_state, do: %{}

    @impl true
    def on_command(_command, state), do: state

    @impl true
    def on_event(%{note: "pushed 1"}, _state), do: raise("mock refused pushed 1")
    def on_event(_event, state), do: state

    @impl true
    def handle_request(_request, state), do: {:ok, %{status: 200}, state}
  end

  defmodule RejectsPushedOne do
    @moduledoc false
    # Rejects the mock event of act 1.
    use PropertyDamage.Model.Projection

    @impl true
    def init, do: %{}

    @impl true
    def apply(_state, %F.Injected{note: "pushed 1"}), do: raise("pushed 1 rejected")
    def apply(state, _event), do: state
  end

  defmodule RejectingModel do
    @moduledoc false
    @behaviour PropertyDamage.Model

    @impl true
    def commands, do: [{F.Act, overrides: &%{n: &1.count}}]

    @impl true
    def command_sequence_projection, do: F.Counter

    @impl true
    def check_projections, do: [RejectsPushedOne]
  end

  setup do
    F.compile!()
    :ok
  end

  defp mocked(mock) do
    {P.MockPushingAdapter, name: "alice", config: %{name: "alice"}, mocks: [{mock, %{}}]}
  end

  defp assert_fails_at_one(report, mock, callback) do
    assert report.kind == :execution_failed
    assert report.failed_at_index == 1

    assert {^mock, ^callback, %RuntimeError{}} = report.failure_reason.type.detail

    text = F.plain(report)
    assert text =~ inspect(mock)
    assert text =~ inspect(callback)
  end

  test "a raising on_command/2 fails the step the mock was told of" do
    report = F.report!(F.Model, [mocked(CommandRaisingMock)])
    assert_fails_at_one(report, CommandRaisingMock, :on_command)
  end

  test "a raising on_event/2 fails the step whose event the mock was told of" do
    report = F.report!(F.Model, [mocked(EventRaisingMock)])
    assert_fails_at_one(report, EventRaisingMock, :on_event)
  end

  test "a projection that rejects a mock event keeps the on_event/2 lines under the step" do
    report = F.report!(RejectingModel, [P.mocked_target("alice", %{})])

    assert report.kind == :check_failed
    assert report.failed_at_index == 1

    lines = report |> F.plain() |> F.listing(nil)
    assert P.log_messages(F.block(lines, "[1]")) == ["mock saw act 1", "mock saw pushed 1"]
  end
end
