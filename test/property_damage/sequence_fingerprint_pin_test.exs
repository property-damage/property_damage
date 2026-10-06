defmodule PropertyDamage.SequenceFingerprintPinTest do
  # A sequence without setup or teardown commands keeps the fingerprint it had
  # before those commands existed: saved traces, the seed library and run
  # comparisons key on it. The literals below were computed before setup and
  # teardown commands were added.
  use ExUnit.Case, async: true

  alias PropertyDamage.{Generator, Sequence}
  alias PropertyDamage.Test.Commands.{CreateItem, MinimalCommand}

  test "a fixed linear sequence keeps its fingerprint" do
    sequence = Sequence.linear([struct(CreateItem, %{}), struct(MinimalCommand, %{})])

    assert Sequence.fingerprint(sequence) ==
             "44206d992f8f3d4af6814f1b5e4aca63b2eb59152bae0c6d4e5cd522f87b25e3"
  end

  test "drawn sequences of a model without setup commands keep their fingerprints" do
    generator = Generator.generate_sequence(PropertyDamage.Test.FullModel, max_commands: 6)

    expected = %{
      7 => "c280980a4e963dd6abb568cf6ce839468edd2f2cda49cb315e80009bbd25c365",
      42 => "326740b9bb2df90cb00ec59edbdc4968e2242e460f63e5cc6b618666f990680e",
      1234 => "437ad90be6009d4b7c92b1827d82b269f6fa0c73f612295057eb6b3e2585718d"
    }

    for {seed, fingerprint} <- expected do
      assert generator |> Generator.generate_value(seed) |> Sequence.fingerprint() == fingerprint
    end
  end
end
