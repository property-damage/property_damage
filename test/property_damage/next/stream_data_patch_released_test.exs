defmodule PropertyDamage.Next.StreamDataPatchReleasedTest do
  # The patch must leave StreamData's draws unchanged for every :rand state
  # that carries no seam handler. This test draws the same tree-based values
  # here, through the patched StreamData, and in a peer VM that loads the
  # released StreamData, and compares them.
  use ExUnit.Case, async: true

  @moduletag :patched_stream_data
  @moduletag timeout: 120_000

  alias PropertyDamage.Test.PatchedStreamData

  # Evaluated in both VMs, so each draws with its own StreamData. Every
  # generator here is built on tree/2, whose level sizes are the draw the
  # patch routes through uniform_in_range/3.
  @draws """
  generators = [
    StreamData.tree(StreamData.integer(0..9), &StreamData.list_of/1),
    StreamData.term(),
    StreamData.iodata(),
    StreamData.chardata()
  ]

  for generator <- generators, size <- [5, 30, 100], seed <- 1..20 do
    generator |> StreamData.resize(size) |> StreamData.seeded(seed) |> Enum.at(0)
  end
  """

  # The peer gets this VM's code path without the patched ebin copy that
  # the test helper put first, so it loads the released StreamData.
  setup do
    patched = StreamData |> :code.which() |> Path.dirname() |> String.to_charlist()
    paths = for path <- :code.get_path(), path != patched, arg <- [~c"-pa", path], do: arg
    {:ok, peer, _node} = :peer.start_link(%{connection: :standard_io, args: paths})
    # Code.eval_string/1 reads the :elixir application's configuration.
    {:ok, _started} = :peer.call(peer, :application, :ensure_all_started, [:elixir])

    on_exit(fn ->
      try do
        :peer.stop(peer)
      catch
        :exit, _ -> :ok
      end
    end)

    %{peer: peer}
  end

  # term/0 draws references, which make_ref/0 creates afresh on every draw.
  # A map becomes its sorted pairs, so the order of reference keys, which
  # follows the references themselves, does not matter.
  defp without_refs(term) when is_reference(term), do: :ref
  defp without_refs([head | tail]), do: [without_refs(head) | without_refs(tail)]

  defp without_refs(%{} = map),
    do:
      {:map,
       map
       |> Map.to_list()
       |> Enum.map(fn {k, v} -> {without_refs(k), without_refs(v)} end)
       |> Enum.sort()}

  defp without_refs(term) when is_tuple(term),
    do: term |> Tuple.to_list() |> Enum.map(&without_refs/1) |> List.to_tuple()

  defp without_refs(term), do: term

  test "tree/2, term/0, iodata/0 and chardata/0 draw the same values as released StreamData",
       %{peer: peer} do
    assert PatchedStreamData.active?()
    refute :peer.call(peer, PatchedStreamData, :active?, [], 60_000)
    refute :peer.call(peer, :code, :which, [StreamData]) |> to_string() =~ "stream_data_patch"

    {released, _binding} = :peer.call(peer, Code, :eval_string, [@draws], 60_000)
    {patched, _binding} = Code.eval_string(@draws)

    assert length(patched) == 4 * 3 * 20
    assert without_refs(patched) == without_refs(released)
  end
end
