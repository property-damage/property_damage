defmodule PropertyDamage.Next.PathReplayFreshVmTest do
  # The final journal of a divergence, saved in this VM, loads in a peer VM
  # that has loaded nothing yet, and its replay there rebuilds the same plan,
  # paths included, and gives the same failure, on either engine. The peer
  # shares this VM's code paths, so it loads the refund model's modules by name.
  use ExUnit.Case, async: true

  @moduletag timeout: 180_000

  alias PropertyDamage.Next
  alias PropertyDamage.Next.Engine.{Native, StreamDataSource}
  alias PropertyDamage.Next.{Failure, Journal}
  alias PropertyDamage.Next.Test.Paths
  alias PropertyDamage.Next.Test.Paths.{Recorded, SplitModel}

  @config %{bug: :short_second_refund}

  defp start_peer(patched?) do
    paths = Enum.flat_map(:code.get_path(), &[~c"-pa", &1])
    {:ok, peer, _node} = :peer.start_link(%{connection: :standard_io, args: paths})

    on_exit(fn ->
      try do
        :peer.stop(peer)
      catch
        :exit, _ -> :ok
      end
    end)

    # The recording-source engine draws through the patched StreamData that
    # this VM loaded, so its directory goes first on the peer's path.
    if patched? do
      patched = StreamData |> :code.which() |> Path.dirname() |> String.to_charlist()
      false = :peer.call(peer, :code, :is_loaded, [StreamData])
      true = :peer.call(peer, :code, :add_patha, [patched])
    end

    peer
  end

  defp assert_replays_in_fresh_vm(engine, patched?) do
    assert {:error, %Failure{} = failure} =
             Next.run(
               model: SplitModel,
               adapter: Paths.Adapter,
               seed: 3,
               max_steps: 8,
               max_plans: 200,
               config: @config,
               engine: engine
             )

    assert {:diverged, :totals, _step, _reference, _variant} = failure.reason
    assert Enum.any?(failure.plan.steps, &(Recorded.pick(&1) not in [0, nil]))

    binary = Journal.to_binary(failure.journal)
    peer = start_peer(patched?)

    refute :peer.call(peer, :code, :is_loaded, [SplitModel])

    assert :peer.call(peer, Journal, :from_binary, [binary, [model: SplitModel]], 60_000) ==
             failure.journal

    remote_plan =
      :peer.call(peer, Next, :plan, [SplitModel, failure.journal, [engine: engine]], 60_000)

    assert remote_plan.steps == failure.plan.steps

    opts = [model: SplitModel, adapter: Paths.Adapter, config: @config, engine: engine]

    assert {:error, %Failure{} = again} =
             :peer.call(peer, Next, :replay, [binary, opts], 60_000)

    assert again.plan.steps == failure.plan.steps

    assert Enum.map(again.plan.steps, &Recorded.path/1) ==
             Enum.map(failure.plan.steps, &Recorded.path/1)

    assert again.step == failure.step
    assert again.reason == failure.reason
  end

  test "on PD's own engine, the replay in a fresh VM gives the same plan and the same divergence" do
    assert_replays_in_fresh_vm(Native, false)
  end

  @tag :patched_stream_data
  test "on the recording-source engine, the replay in a fresh VM gives the same plan and the same divergence" do
    assert_replays_in_fresh_vm(StreamDataSource, true)
  end
end
