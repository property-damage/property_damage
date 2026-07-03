defmodule PropertyDamage.DeterministicIdentityTest do
  @moduledoc """
  DR-036: deterministic symbolic identity + plan fingerprint.

  Placeholder ids are pure functions of their generation coordinates, so two
  independent generations of the same plan are structurally `==` (previously
  broken by `make_ref/0`), and a plan's fingerprint is a stable digest that
  equals iff the plans are the same plan.
  """
  use ExUnit.Case, async: true

  alias PropertyDamage.{Generator, PlaceholderRegistry, Sequence}

  defmodule ItemCreated do
    import PropertyDamage, only: [external: 0]
    defstruct [:name, :quantity, id: external()]
  end

  defmodule CreateItem do
    @behaviour PropertyDamage.Command
    defstruct [:name, :quantity]

    @impl true
    def generator(overrides) do
      # A seed-varying field so different runs generate genuinely different
      # plans (a constant generator would make every run's plan identical).
      base = %{name: StreamData.constant("widget"), quantity: StreamData.integer(1..1000)}
      StreamData.fixed_map(Generator.merge_overrides(base, overrides))
    end
  end

  defmodule Projection do
    @behaviour PropertyDamage.Model.Projection
    @impl true
    def init, do: %{items: %{}}
    @impl true
    def apply(state, %CreateItem{}), do: state
    def apply(state, %ItemCreated{id: id, name: name}), do: put_in(state.items[id], name)
    def apply(state, _other), do: state
  end

  defmodule Model do
    @behaviour PropertyDamage.Model
    @behaviour PropertyDamage.Model.Simulator
    @impl PropertyDamage.Model
    def commands, do: [CreateItem]
    @impl PropertyDamage.Model
    def command_sequence_projection, do: Projection
    @impl PropertyDamage.Model
    def simulator, do: __MODULE__
    @impl PropertyDamage.Model.Simulator
    def simulate(%CreateItem{name: name, quantity: qty}, _state),
      do: [%ItemCreated{name: name, quantity: qty}]

    def simulate(_command, _state), do: []
  end

  defp generate(seed, run_number \\ 0, opts \\ []) do
    Model
    |> Generator.generate_sequence(Keyword.merge([max_commands: 5], opts))
    |> Generator.generate_value(Generator.run_seed(seed, run_number))
  end

  describe "deterministic placeholder identity (DR-036)" do
    test "placeholder id is a pure function of (position, event_index, path)" do
      [p | _] = PlaceholderRegistry.all(generate(1234).registry)
      assert p.id == {p.position, p.event_index, p.path}
    end

    test "two generations of the same plan produce structurally equal sequences" do
      # RED against HEAD: make_ref/0 minted a fresh reference per generation,
      # so these sequences were never == even though semantically identical.
      seq_a = generate(1234)
      seq_b = generate(1234)

      # Sanity: the plan actually carries placeholders (otherwise the claim is
      # vacuous, since make_ref only rides on placeholders).
      refute PlaceholderRegistry.all(seq_a.registry) == []

      assert seq_a == seq_b
      assert seq_a.prefix == seq_b.prefix
    end

    test "ids remain unique within a plan" do
      ids = generate(4321).registry |> PlaceholderRegistry.all() |> Enum.map(& &1.id)
      assert length(ids) == length(Enum.uniq(ids))
    end
  end

  describe "plan fingerprint (DR-036)" do
    test "same plan fingerprints identically" do
      assert Sequence.fingerprint(generate(1234)) == Sequence.fingerprint(generate(1234))
    end

    test "different run_number yields a different plan and a different fingerprint" do
      fp0 = Sequence.fingerprint(generate(1234, 0))
      fp1 = Sequence.fingerprint(generate(1234, 1))
      refute fp0 == fp1
    end

    test "fingerprint is stable when only the derived registry differs" do
      seq = generate(1234)
      stripped = %{seq | registry: nil}
      rebuilt = Sequence.with_registry(seq, PlaceholderRegistry.new())

      assert Sequence.fingerprint(seq) == Sequence.fingerprint(stripped)
      assert Sequence.fingerprint(seq) == Sequence.fingerprint(rebuilt)
    end

    test "fingerprint is a lowercase hex sha256 digest" do
      fp = Sequence.fingerprint(generate(1234))
      assert String.match?(fp, ~r/\A[0-9a-f]{64}\z/)
    end

    test "a placeholder id change (different coordinate) changes the fingerprint" do
      seq = generate(1234)
      [cmd | _] = seq.prefix
      # A structurally different plan must not collide with the original.
      tweaked = %{seq | prefix: [%{cmd | name: "different"} | tl(seq.prefix)]}
      refute Sequence.fingerprint(seq) == Sequence.fingerprint(tweaked)
    end
  end
end
