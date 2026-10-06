defmodule PropertyDamage.SetupCommandsGenerationTest do
  # A model's setup commands are drawn from the run seed before the roots, in
  # written order, and the roots are drawn from the state the setup commands
  # leave. Teardown commands are drawn after the roots from their own seed.
  use ExUnit.Case, async: true

  alias PropertyDamage.{Generator, Placeholder, Sequence}
  alias PropertyDamage.Sequence.Position
  alias PropertyDamage.Test.SetupCommands

  alias PropertyDamage.Test.SetupCommands.{
    Act,
    Cleanup,
    CreateUser,
    Login,
    MakeThing,
    Other,
    Tick
  }

  defp draw(model, seed, max_commands \\ 5) do
    model
    |> Generator.generate_sequence(max_commands: max_commands)
    |> Generator.generate_value(seed)
  end

  defp model!(name, opts), do: SetupCommands.define_model!(Module.concat(__MODULE__, name), opts)

  describe "setup commands" do
    test "are drawn in written order, every entry, with overrides seeing the state so far" do
      model = model!(Standard, setup: SetupCommands.standard_setup())
      sequence = draw(model, 1)

      assert [%CreateUser{name: "fixture"}, %Login{user_id: %Placeholder{} = user}] =
               Sequence.setup_commands(sequence)

      assert user.position == Position.setup(0)
      assert user.path == [:id]
    end

    test "let a root whose when: needs the fixture user be drawn at root 0" do
      with_setup =
        model!(WhenWithSetup,
          commands: SetupCommands.act_roots() ++ [Other],
          setup: SetupCommands.standard_setup()
        )

      without_setup = model!(WhenWithoutSetup, commands: SetupCommands.act_roots() ++ [Other])

      seed =
        Enum.find(1..50, fn seed ->
          match?([%Act{} | _], Sequence.to_list(draw(with_setup, seed)))
        end)

      assert is_integer(seed), "no seed in 1..50 drew Act at root 0 after the setup commands"
      # Without the fixture user no Act can be drawn at all.
      for seed <- 1..50,
          do: refute(Enum.any?(Sequence.to_list(draw(without_setup, seed)), &match?(%Act{}, &1)))

      assert [%Act{n: 0, user_id: %Placeholder{}} | _] = Sequence.to_list(draw(with_setup, seed))
    end

    test "change the roots a seed draws (a seed is stable for a fixed model only)" do
      with_setup = model!(SeedWithSetup, commands: [Other], setup: [CreateUser])
      without_setup = model!(SeedWithoutSetup, commands: [Other])

      for seed <- [1, 2, 3] do
        refute Sequence.to_list(draw(with_setup, seed)) ==
                 Sequence.to_list(draw(without_setup, seed))
      end
    end

    test "do not count toward max_commands" do
      model = model!(MaxCommands, commands: [Other], setup: [CreateUser, Tick])
      sequence = draw(model, 7, 5)

      assert length(Sequence.setup_commands(sequence)) == 2
      assert Sequence.command_count(sequence) == 5
    end

    test "are never passed to terminate_early?/3" do
      model =
        model!(Terminate,
          commands: [Other],
          setup: SetupCommands.standard_setup(),
          terminate: true
        )

      _sequence = draw(model, 3)

      seen = take_terminate_calls()
      assert length(seen) == 5
      assert Enum.all?(seen, &match?(%Other{}, &1))
    end
  end

  describe "a model without setup commands" do
    # Drawn on the base revision before setup commands existed: a model
    # without them must keep every seed's sequence.
    @expected %{
      1 => [
        %Tick{},
        %Tick{},
        %Other{v: 340_121},
        %Other{v: 955_412},
        %Other{v: 76_391}
      ],
      2 => [
        %Other{v: 693_760},
        %Other{v: 99_408},
        %Other{v: 376_399},
        %Other{v: 330_329},
        %Other{v: 898_179}
      ],
      3 => [
        %Other{v: 583_062},
        %MakeThing{},
        %Tick{},
        %Tick{},
        %Tick{}
      ],
      77 => [
        %Other{v: 61_441},
        %Tick{},
        %Other{v: 779_584},
        %Other{v: 501_199},
        %Tick{}
      ]
    }

    test "draws exactly the sequence it drew before setup commands existed" do
      model = model!(BaseDraw, commands: [{Other, weight: 2}, Tick, MakeThing])

      for {seed, expected} <- @expected do
        sequence = draw(model, seed)
        assert Sequence.to_list(sequence) == expected
        assert Sequence.setup_commands(sequence) == []
      end
    end
  end

  describe "teardown commands" do
    test "are drawn against the state after the last root, minting at teardown positions" do
      model =
        model!(Teardown,
          commands: [MakeThing],
          teardown: [
            {Cleanup, overrides: fn state -> %{thing_id: List.last(state.things)} end},
            MakeThing
          ]
        )

      sequence = Generator.teardown_commands(model, draw(model, 5, 3), 5)

      assert [%Cleanup{thing_id: %Placeholder{} = thing}, %MakeThing{}] =
               Sequence.teardown_commands(sequence)

      # The last root (offset 2) produced the thing the cleanup names.
      assert thing.position == Position.prefix(2)

      # The teardown MakeThing mints its own id at its teardown position, and
      # the sequence's registry knows it.
      ids =
        PropertyDamage.PlaceholderRegistry.ids_at_position(
          sequence.registry,
          Position.teardown(1)
        )

      assert [_id] = ids
    end

    test "are a pure function of the model, the sequence and the run seed" do
      model = model!(TeardownPure, commands: [Other], teardown: [CreateUser])
      sequence = draw(model, 9)

      once = Generator.teardown_commands(model, sequence, 9)
      assert once == Generator.teardown_commands(model, sequence, 9)
      assert [%CreateUser{}] = Sequence.teardown_commands(once)
      # The roots and setup commands are left as they were.
      assert Sequence.to_list(once) == Sequence.to_list(sequence)
      # Their draw is their own: it does not depend on the roots' draw.
      refute Sequence.teardown_commands(once) ==
               Sequence.teardown_commands(Generator.teardown_commands(model, sequence, 10))
    end
  end

  defp take_terminate_calls do
    receive do
      {:terminate_early, command} -> [command | take_terminate_calls()]
    after
      0 -> []
    end
  end
end
