defmodule PropertyDamage.Next.LanesOptionsTest do
  # The :lanes, :lane_steps and :yields options of plan/3, run/1 and
  # replay/2: each bad value raises before anything is built or executed,
  # and a journal fixes all three, so a caller who gives one with a journal
  # must give the value the journal recorded.
  use ExUnit.Case, async: true

  alias PropertyDamage.Next
  alias PropertyDamage.Next.Journal
  alias PropertyDamage.Next.Test.Lanes
  alias PropertyDamage.Next.Test.Lanes.Adapter

  @bad_values [
    {[lanes: 3], "the :lanes option is 1 or 2, got: 3"},
    {[lanes: 0], "the :lanes option is 1 or 2, got: 0"},
    {[lanes: nil], "the :lanes option is 1 or 2, got: nil"},
    {[lanes: 2, lane_steps: -1], "lane_steps is a non-negative integer, got: -1"},
    {[lanes: 2, lane_steps: :many], "lane_steps is a non-negative integer, got: :many"},
    {[lanes: 2, yields: -2], "yields is a non-negative integer, got: -2"},
    {[lanes: 2, yields: 1.5], "yields is a non-negative integer, got: 1.5"},
    {[lane_steps: 2], "the :lane_steps option needs lanes: 2"},
    {[lanes: 1, lane_steps: 0], "the :lane_steps option needs lanes: 2"},
    {[yields: 1], "the :yields option needs lanes: 2"},
    {[lanes: 1, yields: 0], "the :yields option needs lanes: 2"}
  ]

  defp two_lane_journal, do: Next.plan(Lanes.Model, 1, max_steps: 2, lanes: 2).journal
  defp one_lane_journal, do: Next.plan(Lanes.Model, 1, max_steps: 2).journal

  describe "a bad lane option" do
    test "raises ArgumentError from plan/3 with a seed" do
      for {opts, message} <- @bad_values do
        error = assert_raise ArgumentError, fn -> Next.plan(Lanes.Model, 1, opts) end
        assert {opts, error.message} == {opts, message}
      end
    end

    test "raises ArgumentError from run/1 before the adapter is called" do
      for {opts, message} <- @bad_values do
        run = [model: Lanes.Model, adapter: Adapter, seed: 1, config: %{recorder: self()}]
        error = assert_raise ArgumentError, fn -> Next.run(run ++ opts) end

        assert {opts, error.message} == {opts, message}
        assert Lanes.executions() == []
      end
    end
  end

  describe "a journal" do
    test "records lanes, lane_steps and yields, and a plan rebuilt from it needs none of them" do
      journal = two_lane_journal()

      assert Lanes.get(journal, :lanes) == %{count: 2, steps: 3, yields: 1}
      assert Next.plan(Lanes.Model, journal) == Next.plan(Lanes.Model, 1, max_steps: 2, lanes: 2)

      assert Next.plan(Lanes.Model, journal, lanes: 2, lane_steps: 3, yields: 1) ==
               Next.plan(Lanes.Model, journal)
    end

    test "refuses a lane option that differs from what it recorded, in plan/3 and replay/2" do
      cases = [
        {two_lane_journal(), [lanes: 1],
         "the journal was recorded with lanes 2, but the :lanes option is 1"},
        {two_lane_journal(), [lane_steps: 4],
         "the journal was recorded with lane_steps 3, but the :lane_steps option is 4"},
        {two_lane_journal(), [yields: 2],
         "the journal was recorded with yields 1, but the :yields option is 2"},
        {one_lane_journal(), [lanes: 2],
         "the journal was recorded with lanes 1, but the :lanes option is 2"}
      ]

      for {journal, opts, message} <- cases do
        error = assert_raise ArgumentError, fn -> Next.plan(Lanes.Model, journal, opts) end
        assert {opts, error.message} == {opts, message}

        for saved <- [journal, Journal.to_binary(journal)] do
          replay = [model: Lanes.Model, adapter: Adapter, config: %{recorder: self()}]
          error = assert_raise ArgumentError, fn -> Next.replay(saved, replay ++ opts) end

          assert {opts, error.message} == {opts, message}
          assert Lanes.executions() == []
        end
      end
    end

    test "of one lane refuses :lane_steps and :yields, which need two lanes" do
      for {opts, message} <- [
            {[lane_steps: 3], "the :lane_steps option needs lanes: 2"},
            {[yields: 1], "the :yields option needs lanes: 2"}
          ] do
        error =
          assert_raise ArgumentError, fn -> Next.plan(Lanes.Model, one_lane_journal(), opts) end

        assert error.message == message
      end
    end

    test "replays with the lanes it recorded when the caller gives none" do
      journal = two_lane_journal()
      config = %{recorder: self()}

      assert {:ok, _} = Next.replay(journal, model: Lanes.Model, adapter: Adapter, config: config)
      assert [%{points: points, teardowns: 1}] = Lanes.executions()

      plan = Next.plan(Lanes.Model, journal)
      assert length(points) > length(plan.steps)
    end
  end
end
