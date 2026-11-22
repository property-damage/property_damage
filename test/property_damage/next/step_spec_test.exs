defmodule PropertyDamage.Next.StepSpecTest do
  use ExUnit.Case, async: true

  alias PropertyDamage.Next.{Command, Gen, StepSpec}
  alias PropertyDamage.Next.Test.Fixtures.{NotACommand, OptsEcho}
  alias PropertyDamage.Next.Test.Scheme.{Pay, Refund}
  alias PropertyDamage.Next.Test.Terms

  defmodule Layers do
    @moduledoc false
    import PropertyDamage.Next.StepSpec, only: [put_command_field: 3]

    def small_amounts(%StepSpec{command: Pay} = spec),
      do: put_command_field(spec, :amount, Gen.integer(1..10))

    def small_amounts(spec), do: spec

    def heavier(%StepSpec{} = spec), do: %{spec | weight: spec.weight + 1}

    def unchanged(spec), do: spec

    def not_a_spec(_spec), do: :not_a_spec

    def echo_amount(%{amount: amount}), do: Gen.integer(amount..amount)
  end

  defp pay_spec, do: hd(StepSpec.normalize([Pay]))

  defp message(fun), do: Exception.message(Terms.raised(fun))

  describe "normalize/1" do
    test "a bare module is the module with PD's defaults" do
      assert [%StepSpec{command: Pay, weight: 1, when: nil, command_opts: []} = spec] =
               StepSpec.normalize([Pay])

      assert spec.assigns == %{}
      assert spec.changes == []
      assert spec.history == []
    end

    test "a module with a keyword list takes weight, when: and command_opts" do
      possible? = &Refund.possible?/1

      assert [
               %StepSpec{
                 command: Refund,
                 weight: 3,
                 when: ^possible?,
                 command_opts: [max_share: 0.5]
               }
             ] =
               StepSpec.normalize([
                 {Refund, weight: 3, when: possible?, command_opts: [max_share: 0.5]}
               ])
    end

    test "a spec struct is taken as it is" do
      spec = pay_spec() |> StepSpec.assign(:note, Gen.member_of([:quiet]))
      assert StepSpec.normalize([spec]) == [spec]
    end

    test "PD's keys are checked strictly" do
      assert message(fn -> StepSpec.normalize([{Pay, wieght: 2}]) end) =~ "wieght"
      assert message(fn -> StepSpec.normalize([{Pay, opts: [max_share: 0.5]}]) end) =~ "opts"
    end

    test "there is no overrides key" do
      assert message(fn -> StepSpec.normalize([{Pay, overrides: %{amount: 5}}]) end) =~
               "overrides"
    end

    test "a module that is not a command module is refused, naming it" do
      assert message(fn -> StepSpec.normalize([NotACommand]) end) =~ inspect(NotACommand)
      assert message(fn -> StepSpec.normalize([{String, []}]) end) =~ "String"
    end
  end

  describe "assigns" do
    test "assign/3 sets one key to a generator" do
      generator = Gen.member_of([:quiet, :loud])
      assert StepSpec.assign(pay_spec(), :note, generator).assigns == %{note: generator}
    end

    test "assign/3 accepts every kind of generator and a mint" do
      for generator <- [
            Gen.integer(1..3),
            Gen.constant(:x),
            StreamData.integer(1..3),
            :an_atom,
            {StreamData.boolean(), :an_atom},
            PropertyDamage.mint_per_run(:uuid)
          ] do
        assert %StepSpec{} = StepSpec.assign(pay_spec(), :note, generator)
      end
    end

    test "assign/3 refuses a value that is not a generator, at the call, naming the key" do
      for value <- [5, 1..5, fn -> 1 end, %{a: Gen.boolean()}, [1, 2], "text"] do
        error = Terms.raised(fn -> StepSpec.assign(pay_spec(), :note, value) end)

        assert %ArgumentError{} = error
        assert Exception.message(error) =~ ":note"
        assert Exception.message(error) =~ "constant"
      end
    end

    test "assign/3 refuses a from/2 marker, which belongs in a command's map" do
      marker = Command.from(:amount, fn a -> Gen.integer(a..a) end)
      assert %ArgumentError{} = Terms.raised(fn -> StepSpec.assign(pay_spec(), :note, marker) end)
    end

    test "merge_assigns/2 sets each key" do
      spec = StepSpec.merge_assigns(pay_spec(), note: Gen.boolean(), tag: Gen.member_of([:t]))
      assert Map.keys(spec.assigns) |> Enum.sort() == [:note, :tag]
    end

    test "assign_from_command/3 records a function of the drawn command" do
      spec = StepSpec.assign_from_command(pay_spec(), :echo, &Layers.echo_amount/1)
      assert %StepSpec.FromCommand{} = spec.assigns.echo
    end
  end

  describe "command changes" do
    test "put_command_field/3 refuses a field the command does not have, at the call" do
      assert message(fn -> StepSpec.put_command_field(pay_spec(), :amout, Gen.integer(1..2)) end) =~
               "amout"
    end

    test "put_command_field/3 refuses a number or a range, at the call, naming the field" do
      for value <- [5, 1..5] do
        error = Terms.raised(fn -> StepSpec.put_command_field(pay_spec(), :amount, value) end)

        assert %ArgumentError{} = error
        assert Exception.message(error) =~ ":amount"
        assert Exception.message(error) =~ "constant"
      end
    end

    test "put_command_field/3, merge_command_fields/2 and update_command/2 record changes" do
      spec =
        pay_spec()
        |> StepSpec.put_command_field(:amount, Gen.integer(1..5))
        |> StepSpec.merge_command_fields(amount: Gen.integer(6..7))
        |> StepSpec.update_command(fn fields, _state -> fields end)

      assert length(spec.changes) == 3
    end

    test "merge_command_opts/2 merges into the options the module reads" do
      [spec] = StepSpec.normalize([{OptsEcho, command_opts: [a: 1, b: 2]}])

      merged = StepSpec.merge_command_opts(spec, b: 3, c: 4)
      assert Enum.sort(merged.command_opts) == [a: 1, b: 3, c: 4]
    end
  end

  describe "transform/2" do
    test "applies one function to every spec" do
      specs = StepSpec.normalize([Pay, Refund])
      [pay, refund] = StepSpec.transform(specs, &Layers.heavier/1)

      assert pay.weight == 2
      assert refund.weight == 2
    end

    test "applies each function of a list" do
      specs = StepSpec.normalize([{Pay, weight: 2}])
      [pay] = StepSpec.transform(specs, [&Layers.heavier/1, &Layers.small_amounts/1])

      assert pay.weight == 3
      assert length(pay.changes) == 1
    end

    test "records the layer in the history of the spec it changed" do
      [pay, refund] =
        StepSpec.transform(StepSpec.normalize([Pay, Refund]), &Layers.small_amounts/1)

      assert Terms.mentions?(pay.history, &Layers.small_amounts/1)
      assert refund.changes == []
    end

    test "a layer that changes no spec does not raise and is recorded" do
      specs = StepSpec.normalize([Pay, Refund])
      result = StepSpec.transform(specs, &Layers.unchanged/1)

      assert Enum.map(result, &%{&1 | history: []}) == specs
      layer = &Layers.unchanged/1
      assert Enum.any?(result, &Terms.mentions?(&1.history, layer))
    end

    test "a layer that returns something other than a spec raises, naming the function" do
      assert message(fn ->
               StepSpec.transform(StepSpec.normalize([Pay]), &Layers.not_a_spec/1)
             end) =~
               "not_a_spec"
    end

    test "takes a list of specs only" do
      assert %{__exception__: true} =
               Terms.raised(fn -> StepSpec.transform(pay_spec(), &Layers.unchanged/1) end)

      assert %{__exception__: true} =
               Terms.raised(fn -> StepSpec.transform([Pay], &Layers.unchanged/1) end)
    end
  end
end
