defmodule PropertyDamage.Next.JournalBytesTest do
  # Equal journals encode to equal bytes in every VM. Without the
  # `:deterministic` option, the encoder writes the keys of a map in the
  # order of their atoms' creation in the running VM, so two VMs that
  # created the same atoms in a different order write different bytes for
  # one map. Each test starts two peer VMs that create the atoms of a
  # stored value in opposite orders, then encodes the same journal in both.
  use ExUnit.Case, async: true

  alias PropertyDamage.Next.Journal

  @moduletag timeout: 120_000

  defp start_peer do
    paths = Enum.flat_map(:code.get_path(), &[~c"-pa", &1])
    {:ok, peer, _node} = :peer.start_link(%{connection: :standard_io, args: paths})

    on_exit(fn ->
      try do
        :peer.stop(peer)
      catch
        :exit, _ -> :ok
      end
    end)

    peer
  end

  # The peer creates the atoms in `names` in that order, then runs fun.
  defp encode_after_creating(names, journal) do
    peer = start_peer()
    for name <- names, do: :peer.call(peer, :erlang, :binary_to_atom, [name, :utf8])
    :peer.call(peer, Journal, :to_binary, [journal], 60_000)
  end

  defp journal(value) do
    %Journal{
      seed: 1,
      max_steps: 1,
      entries: %{{{0, 1}, :command, :value} => {:member, value, 0}},
      fingerprint: nil
    }
  end

  test "equal journals encode to equal bytes in two VMs that created their atoms in opposite order" do
    names = for n <- 1..12, do: "journal_bytes_atom_#{n}"
    value = Map.new(names, &{String.to_atom(&1), &1})

    first = encode_after_creating(names, journal(value))
    second = encode_after_creating(Enum.reverse(names), journal(value))

    assert first == second
  end

  test "the encoded journal still loads and equals the saved one" do
    value = %{journal_bytes_left: 1, journal_bytes_right: 2}

    assert journal(value) |> Journal.to_binary() |> Journal.from_binary() == journal(value)
  end
end
