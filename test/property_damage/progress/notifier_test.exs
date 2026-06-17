defmodule PropertyDamage.Progress.NotifierTest do
  use ExUnit.Case, async: true

  alias PropertyDamage.Progress
  alias PropertyDamage.Progress.{LoadResult, LoadUpdate, Notifier}

  defp upd(n), do: Progress.new(%LoadUpdate{snapshot: %{n: n}})
  defp result, do: Progress.new(%LoadResult{report: %{final: true}})

  describe "decimate/1 (pure)" do
    test "keeps every other progress update, preserving order" do
      buffer = for n <- 1..6, do: upd(n)
      kept = Notifier.decimate(buffer) |> Enum.map(& &1.data.snapshot.n)
      assert kept == [1, 3, 5]
    end

    test "never drops a :result update" do
      buffer = [upd(1), upd(2), result(), upd(3), upd(4)]

      kinds =
        buffer
        |> Notifier.decimate()
        |> Enum.map(&Progress.kind/1)

      # progress at indices 0,1,2,3 -> keep 0 and 2; result always kept
      assert Enum.count(kinds, &(&1 == :result)) == 1
      assert kinds == [:progress, :result, :progress]
    end
  end

  describe "delivery" do
    test "delivers all updates in order then the result, under no overflow" do
      parent = self()
      {:ok, n} = Notifier.start_link([fn p -> send(parent, p.data) end], capacity: 256)

      Notifier.emit(n, upd(1))
      Notifier.emit(n, upd(2))
      Notifier.emit(n, result())
      Notifier.flush(n)

      assert_receive %LoadUpdate{snapshot: %{n: 1}}
      assert_receive %LoadUpdate{snapshot: %{n: 2}}
      assert_receive %LoadResult{report: %{final: true}}
    end

    test "guarantees the terminal result and decimates updates under backpressure" do
      parent = self()
      ref = make_ref()

      # The first consumer call blocks (waiting for a :release in the notifier's
      # own mailbox, where the consumer runs) so a burst of emits piles into the
      # buffer (capacity 4) and gets decimated while the notifier is busy.
      consumer = fn p ->
        if match?(%LoadUpdate{snapshot: %{n: 1}}, p.data) do
          send(parent, {:blocking, ref})

          receive do
            {:release, ^ref} -> :ok
          end
        end

        send(parent, {:delivered, p.data})
      end

      {:ok, n} = Notifier.start_link([consumer], capacity: 4)

      Notifier.emit(n, upd(1))
      assert_receive {:blocking, ^ref}

      # Burst arrives while the notifier is stuck in consumer(1).
      for i <- 2..20, do: Notifier.emit(n, upd(i))
      Notifier.emit(n, result())

      # Release into the notifier process, where the consumer's receive is waiting.
      send(n, {:release, ref})
      Notifier.flush(n)

      delivered =
        collect_delivered([])
        |> Enum.map(fn
          %LoadUpdate{snapshot: %{n: i}} -> i
          %LoadResult{} -> :result
        end)

      # The result is always delivered.
      assert :result in delivered
      # Update 1 (delivered before the burst) is present.
      assert 1 in delivered
      # Fewer than all 20 updates survive (decimation happened).
      update_ns = Enum.reject(delivered, &(&1 == :result))
      assert length(update_ns) < 20
      # Order is preserved (ascending), result last.
      assert List.last(delivered) == :result
      assert update_ns == Enum.sort(update_ns)
    end
  end

  defp collect_delivered(acc) do
    receive do
      {:delivered, data} -> collect_delivered([data | acc])
    after
      100 -> Enum.reverse(acc)
    end
  end
end
