defmodule PropertyDamage.Next.MintStampTest do
  # Generation stamps each mint_per_run/1 marker once, with its slot and
  # field. A marker that the model reads back from its predicted state keeps
  # its stamp, so a retry that sends an earlier payment again sends the same
  # key. The value is still fresh per execution, and no PD term reaches the
  # system under test.
  use ExUnit.Case, async: true

  alias PropertyDamage.Next
  alias PropertyDamage.Next.{Journal, Step}
  alias PropertyDamage.Next.Test.Leak
  alias PropertyDamage.Next.Test.Retry.{Adapter, Again, Model, Pay}

  @max_steps 6
  @uuid ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/

  @moduletag timeout: 120_000

  defp plan(seed), do: Next.plan(Model, seed, max_steps: @max_steps)

  defp retrying_seeds do
    seeds =
      Enum.filter(1..40, fn seed ->
        Enum.any?(plan(seed).steps, &match?(%Step{command: %Again{}}, &1))
      end)

    assert length(seeds) >= 3
    Enum.take(seeds, 5)
  end

  # Executes `journal` once; returns what the system received, in order.
  defp execute(journal) do
    assert {:ok, _} =
             Next.replay(journal, model: Model, adapter: Adapter, config: %{recorder: self()})

    collect([])
  end

  defp collect(acc) do
    receive do
      {:retry_received, kind, fields} -> collect([{kind, fields} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  describe "at the system under test" do
    test "a retry sends the key of the payment it repeats, in the same execution" do
      for seed <- retrying_seeds() do
        received = execute(plan(seed).journal)

        Enum.reduce(received, [], fn
          {:pay, fields}, paid ->
            [fields | paid]

          {:again, %{amount: amount, key: key}}, paid ->
            assert Enum.any?(paid, &(&1.key == key and &1.amount == amount)),
                   "the retry's key #{inspect(key)} is not the key of an earlier payment"

            paid
        end)

        assert Enum.any?(received, &match?({:again, _}, &1))
      end
    end

    test "every key is a concrete value, and two executions of one journal send different keys" do
      for seed <- retrying_seeds() do
        journal = plan(seed).journal
        keys = fn received -> for {_kind, %{key: key}} <- received, do: key end

        first = keys.(execute(journal))
        second = keys.(execute(journal))

        assert Enum.all?(first ++ second, &(is_binary(&1) and &1 =~ @uuid))
        assert MapSet.disjoint?(MapSet.new(first), MapSet.new(second))
      end
    end

    test "two separate mint_per_run/1 calls send two values" do
      for seed <- retrying_seeds() do
        pays = for {:pay, fields} <- execute(plan(seed).journal), do: fields
        minted = Enum.flat_map(pays, &[&1.key, &1.request])

        assert Enum.uniq(minted) == minted
      end
    end

    test "no PD term reaches the system" do
      for seed <- retrying_seeds(), {_kind, fields} <- execute(plan(seed).journal) do
        assert Leak.find(fields) == [], "the system received PD terms: #{inspect(fields)}"
      end
    end
  end

  describe "in the plan and the journal" do
    test "each marker is stamped: one per slot and field, shared by every step that holds it" do
      for seed <- retrying_seeds() do
        plan = plan(seed)
        pays = for %Step{command: %Pay{} = pay} <- plan.steps, do: pay
        markers = Enum.flat_map(pays, &[&1.key, &1.request])

        assert Enum.all?(markers, &match?(%PropertyDamage.Mint{kind: :uuid}, &1))
        assert Enum.uniq(markers) == markers
        refute PropertyDamage.mint_per_run(:uuid) in markers

        for %Step{key: key, command: %Again{original: original}} <- plan.steps do
          assert original.key in Enum.map(pays, & &1.key)

          assert {:member, ^original, _index} =
                   plan.journal.entries[{key, :command, :original}]
        end
      end
    end

    test "a journal holding a stamped marker rebuilds the identical plan" do
      for seed <- retrying_seeds() do
        plan = plan(seed)
        loaded = plan.journal |> Journal.to_binary() |> Journal.from_binary()

        assert loaded == plan.journal
        assert Next.plan(Model, loaded).steps == plan.steps
      end
    end
  end

  describe "in a fresh VM" do
    setup do
      paths = Enum.flat_map(:code.get_path(), &[~c"-pa", &1])
      {:ok, peer, _node} = :peer.start_link(%{connection: :standard_io, args: paths})

      on_exit(fn ->
        try do
          :peer.stop(peer)
        catch
          :exit, _ -> :ok
        end
      end)

      %{peer: peer}
    end

    test "a journal holding a stamped marker loads, rebuilds the identical plan and replays",
         %{peer: peer} do
      [seed | _] = retrying_seeds()
      plan = plan(seed)
      binary = Journal.to_binary(plan.journal)

      assert :peer.call(peer, Journal, :from_binary, [binary, [model: Model]], 60_000) ==
               plan.journal

      rebuilt = :peer.call(peer, Next, :plan, [Model, plan.journal], 60_000)
      assert rebuilt.steps == plan.steps

      assert {:ok, _} =
               :peer.call(peer, Next, :replay, [binary, [model: Model, adapter: Adapter]], 60_000)
    end
  end
end
