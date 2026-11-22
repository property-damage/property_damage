defmodule PropertyDamage.Next.GenerationTest do
  use ExUnit.Case, async: true

  alias PropertyDamage.Next
  alias PropertyDamage.Next.{Gen, Step, StepSpec}
  alias PropertyDamage.Next.Test.Fixtures, as: F
  alias PropertyDamage.Next.Test.Scheme.{Model, OnlyRefundModel, Pay, Refund, RefundedTotal}
  alias PropertyDamage.Next.Test.Terms

  defmodule Shaping do
    @moduledoc false
    alias PropertyDamage.Next.{Gen, StepSpec}

    def five(%StepSpec{command: Pay} = spec),
      do: StepSpec.put_command_field(spec, :amount, Gen.integer(5..5))

    def five(spec), do: spec

    def seven(%StepSpec{command: Pay} = spec),
      do: StepSpec.merge_command_fields(spec, amount: Gen.integer(7..7))

    def seven(spec), do: spec

    # Pay amounts count up from 100 with the number of earlier payments.
    def counting(%StepSpec{command: Pay} = spec), do: StepSpec.update_command(spec, &count_up/2)
    def counting(spec), do: spec

    def count_up(fields, state) do
      n = 100 + length(state.order)
      Map.put(fields, :amount, Gen.integer(n..n))
    end

    def echo_amount(%{amount: amount}), do: Gen.integer(amount..amount)

    def with_assigns(%StepSpec{command: Pay} = spec) do
      spec
      |> StepSpec.assign(:note, Gen.member_of([:quiet]))
      |> StepSpec.assign_from_command(:echo, &echo_amount/1)
      |> StepSpec.assign(:request, PropertyDamage.mint_per_run(:uuid))
    end

    def with_assigns(spec), do: spec
  end

  defmodule ShapedModel do
    @moduledoc false
    # The base model's specs, run through layers that fix Pay's amount: first
    # to 5, then to 7.
    use PropertyDamage.Next.Test.Scheme.Variants

    def steps, do: StepSpec.transform(Model.steps(), [&Shaping.five/1, &Shaping.seven/1])
  end

  defmodule CountingModel do
    @moduledoc false
    use PropertyDamage.Next.Test.Scheme.Variants

    def steps, do: StepSpec.transform(Model.steps(), &Shaping.counting/1)
  end

  defmodule AssignsModel do
    @moduledoc false
    use PropertyDamage.Next.Test.Scheme.Variants

    def steps, do: StepSpec.transform(Model.steps(), &Shaping.with_assigns/1)
  end

  defmodule MergedOptsModel do
    @moduledoc false
    use PropertyDamage.Next.Model

    def steps do
      [{F.OptsEcho, command_opts: [a: 1]}]
      |> StepSpec.normalize()
      |> Enum.map(&StepSpec.merge_command_opts(&1, b: 2))
    end

    def simulator, do: F.NullSimulator
    def command_sequence_projection, do: F.EmptyProjection
  end

  # The fields each command of the running example draws; mints are not drawn.
  @drawn %{Pay => [:amount], Refund => [:amount, :payment], RefundedTotal => [:payment]}

  defp message(fun), do: Exception.message(Terms.raised(fun))

  defp plans(model, seeds, max_steps),
    do: Enum.map(seeds, &Next.plan(model, &1, max_steps: max_steps))

  describe "journal keys" do
    test "every key of a one-lane plan starts with lane 0 and a slot counted from 1" do
      for plan <- plans(Model, 1..10, 12), key <- Map.keys(plan.journal.entries) do
        slot =
          case key do
            {{0, slot}, _kind} -> slot
            {{0, slot}, _kind, _name} -> slot
            other -> flunk("key #{inspect(other)} does not start with {0, slot}")
          end

        assert slot in 1..12, "key #{inspect(key)} is outside the plan's slots"
      end
    end

    test "a plan has one step per slot when a spec is always eligible, keyed {0, slot}" do
      for plan <- plans(Model, 1..10, 12) do
        assert Enum.map(plan.steps, & &1.key) == for(slot <- 1..12, do: {0, slot})
      end
    end

    test "a slot where no spec is eligible yields no step and no entry" do
      plan = Next.plan(OnlyRefundModel, 4, max_steps: 6)

      assert plan.steps == []
      assert plan.journal.entries == %{}
      assert plan.withdrawn == []
    end
  end

  describe "one draw per field" do
    test "the journal holds a pick per step and one entry per drawn field, under its own key" do
      for plan <- plans(Model, 1..10, 15) do
        expected =
          for %Step{key: key, command: %module{}} <- plan.steps,
              entry_key <- [{key, :pick} | Enum.map(@drawn[module], &{key, :command, &1})],
              into: MapSet.new(),
              do: entry_key

        assert MapSet.new(Map.keys(plan.journal.entries)) == expected
      end
    end

    test "each kind of draw stores its own entry, and the command holds the drawn value" do
      plan = Next.plan(F.ProbeModel, 9, max_steps: 8)
      entries = plan.journal.entries

      expected_keys =
        for slot <- 1..8,
            suffix <- [:pick | Enum.map([:color, :count, :flag, :label, :size], &{:command, &1})],
            into: MapSet.new() do
          case suffix do
            :pick -> {{0, slot}, :pick}
            {:command, field} -> {{0, slot}, :command, field}
          end
        end

      assert MapSet.new(Map.keys(entries)) == expected_keys

      for %Step{key: key, command: %F.Probe{} = probe} <- plan.steps do
        assert entries[{key, :command, :count}] == {:integer, probe.count, 1..9}

        assert entries[{key, :command, :size}] ==
                 {:integer, probe.size, probe.count..(probe.count + 3)}

        assert {:member, color, color_index} = entries[{key, :command, :color}]
        assert color == probe.color
        assert Enum.at(F.Probe.colors(), color_index) == color

        assert {:member, flag, flag_index} = entries[{key, :command, :flag}]
        assert flag == probe.flag
        assert Enum.at([false, true], flag_index) == flag

        assert entries[{key, :command, :label}] == {:stream_data, probe.label}
        assert is_binary(probe.label)
      end
    end

    test "a field the map does not name has no entry and keeps its struct default" do
      for %Step{command: probe} <- Next.plan(F.ProbeModel, 2, max_steps: 5).steps do
        assert probe.untouched == :default
      end

      plan = Next.plan(F.WeightedModel, 3, max_steps: 20)
      plain_steps = for %Step{command: %F.Plain{}} = step <- plan.steps, do: step

      for step <- plain_steps do
        assert step.command == %F.Plain{}

        refute Enum.any?(
                 Map.keys(plan.journal.entries),
                 &match?({k, :command, _} when k == step.key, &1)
               )
      end
    end

    test "a mint field records no entry and the plan holds the mint marker" do
      plan = Next.plan(Model, 4, max_steps: 10)

      for %Step{key: key, command: %Pay{idempotency_key: marker}} <- plan.steps do
        assert %PropertyDamage.Mint{kind: :uuid} = marker
        refute Map.has_key?(plan.journal.entries, {key, :command, :idempotency_key})
      end
    end
  end

  describe "the pick and the command" do
    test "every command is a struct of its spec's command module" do
      for plan <- plans(Model, 1..10, 15), %Step{command: %module{}} <- plan.steps do
        assert module in [Pay, Refund, RefundedTotal]
      end
    end

    test "the pick entry names the step's spec id and module" do
      for plan <- plans(Model, 1..10, 15),
          %Step{key: key, command: %module{}} = step <- plan.steps do
        assert plan.journal.entries[{key, :pick}] == {:pick, step.spec_id, module}
      end
    end

    test "PD gives each spec of the model its own id" do
      ids =
        for plan <- plans(Model, 1..20, 15),
            %Step{command: %module{}} = step <- plan.steps,
            into: MapSet.new(),
            do: {module, step.spec_id}

      by_module = Enum.group_by(ids, &elem(&1, 0), &elem(&1, 1))

      assert Map.keys(by_module) |> Enum.sort() == Enum.sort([Pay, Refund, RefundedTotal])
      assert Enum.all?(by_module, fn {_module, ids} -> length(ids) == 1 end)
      assert by_module |> Map.values() |> List.flatten() |> Enum.uniq() |> length() == 3
    end

    test "a spec is picked only when its when: holds" do
      for plan <- plans(Model, 1..20, 15) do
        [first | _] = plan.steps
        assert %Pay{} = first.command
      end
    end

    test "the pick follows the weights" do
      modules =
        for plan <- plans(F.WeightedModel, 1..20, 20),
            %Step{command: %module{}} <- plan.steps,
            do: module

      probes = Enum.count(modules, &(&1 == F.Probe))
      plains = Enum.count(modules, &(&1 == F.Plain))

      assert plains > 0
      assert probes > 3 * plains
    end
  end

  describe "generator/2" do
    test "receives the spec's command options" do
      for %Step{command: echo} <- Next.plan(F.OptsModel, 1, max_steps: 3).steps do
        assert echo.seen == [max_share: 0.25]
      end
    end

    test "receives the options merge_command_opts/2 wrote" do
      for %Step{command: echo} <- Next.plan(MergedOptsModel, 1, max_steps: 3).steps do
        assert Enum.sort(echo.seen) == [a: 1, b: 2]
      end
    end

    test "receives the predicted state" do
      for plan <- plans(Model, 1..20, 20) do
        Enum.reduce(plan.steps, [], fn
          %Step{command: %Pay{amount: amount}}, paid ->
            [amount | paid]

          %Step{command: %Refund{amount: amount}}, paid ->
            assert paid != []
            assert amount in 1..max(div(Enum.max(paid), 2), 1)
            paid

          _step, paid ->
            paid
        end)
      end
    end

    test "returning a struct raises at the first draw, naming the module" do
      assert message(fn -> Next.plan(F.StructGeneratorModel, 1, max_steps: 2) end) =~
               inspect(F.StructGenerator)
    end

    test "returning one generator raises at the first draw, naming the module" do
      assert message(fn -> Next.plan(F.SingleGeneratorModel, 1, max_steps: 2) end) =~
               inspect(F.SingleGenerator)
    end
  end

  describe "values in a generator map" do
    test "a number or a bare range raises ArgumentError at the first draw, naming module and field" do
      for {model, command} <- [
            {F.NumberFieldModel, F.NumberField},
            {F.RangeFieldModel, F.RangeField}
          ] do
        assert [%StepSpec{}] = model.steps()

        error = Terms.raised(fn -> Next.plan(model, 1, max_steps: 2) end)

        assert %ArgumentError{} = error
        assert Exception.message(error) =~ inspect(command)
        assert Exception.message(error) =~ ":amount"
        assert Exception.message(error) =~ "constant"
      end
    end
  end

  describe "from/2" do
    test "the function receives the named field's value, or a map of exactly the named fields" do
      for %Step{command: chain} <- Next.plan(F.ChainModel, 6, max_steps: 10).steps do
        assert chain.echo == chain.base
        assert chain.sum == chain.base + chain.other
        assert chain.next in chain.echo..(chain.echo + 1)
      end
    end

    test "each dependent field is drawn under its own key" do
      plan = Next.plan(F.ChainModel, 6, max_steps: 3)

      for %Step{key: key, command: chain} <- plan.steps, field <- [:echo, :sum, :next] do
        assert {:integer, value, _range} = plan.journal.entries[{key, :command, field}]
        assert value == Map.fetch!(chain, field)
      end
    end

    test "a function that returns another from/2 raises, naming the module" do
      assert message(fn -> Next.plan(F.FromReturnsFromModel, 1, max_steps: 2) end) =~
               inspect(F.FromReturnsFrom)
    end

    test "a from/2 that names an unknown field raises, naming the module and the field" do
      text = message(fn -> Next.plan(F.UnknownFromModel, 1, max_steps: 2) end)

      assert text =~ inspect(F.UnknownFrom)
      assert text =~ "missing_source"
    end

    test "a cycle of from/2 fields raises, naming the module" do
      assert message(fn -> Next.plan(F.CycleFromModel, 1, max_steps: 2) end) =~
               inspect(F.CycleFrom)
    end

    test "PD's own engine raises when the function returns a StreamData generator" do
      assert message(fn -> Next.plan(F.PlainFromModel, 1, max_steps: 2) end) =~
               inspect(F.PlainFrom)

      assert message(fn -> Next.plan(F.DelegatedFromModel, 1, max_steps: 2) end) =~
               inspect(F.DelegatedFrom)
    end
  end

  describe "spec changes at the draw" do
    test "recorded changes apply in layer order" do
      for plan <- plans(ShapedModel, 1..5, 10), %Step{command: %Pay{} = pay} <- plan.steps do
        assert pay.amount == 7
      end
    end

    test "update_command/2 receives the field map and the predicted state" do
      plan = Next.plan(CountingModel, 3, max_steps: 12)
      amounts = for %Step{command: %Pay{amount: amount}} <- plan.steps, do: amount

      assert amounts == Enum.to_list(100..(100 + length(amounts) - 1))
    end

    test "assigns are drawn under their own keys; a dependent assign reads the drawn command" do
      plan = Next.plan(AssignsModel, 5, max_steps: 10)

      for %Step{key: key, command: %Pay{amount: amount}, assigns: assigns} <- plan.steps do
        assert assigns.note == :quiet
        assert assigns.echo == amount
        assert %PropertyDamage.Mint{} = assigns.request

        assert plan.journal.entries[{key, :assigns, :note}] == {:member, :quiet, 0}
        assert plan.journal.entries[{key, :assigns, :echo}] == {:integer, amount, amount..amount}
        refute Map.has_key?(plan.journal.entries, {key, :assigns, :request})
      end
    end
  end

  describe "the engine option" do
    test "generation draws every field through the engine it is given" do
      plan = Next.plan(F.ProbeModel, 3, max_steps: 6, engine: F.LowestEngine)

      for %Step{command: probe} <- plan.steps do
        assert probe.count == 1
        assert probe.size == 1
        assert probe.color == :red
        assert probe.flag == false
      end
    end
  end

  test "a drawn description never reaches a command" do
    for plan <- plans(F.ProbeModel, 1..5, 5), %Step{command: probe} <- plan.steps do
      refute Terms.mentions?(Map.from_struct(probe), Gen.boolean())
      assert Enum.all?(Map.from_struct(probe), fn {_k, v} -> not match?(%Gen{}, v) end)
    end
  end
end
