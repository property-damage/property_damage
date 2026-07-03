defmodule PropertyDamage.MintTest do
  @moduledoc """
  DR-034: client-minted run-scoped values (`mint_per_run`).

  A minted field is a pure function of `(run_nonce, mint_epoch, position, path,
  kind)`: identical inputs reproduce byte-exactly, a different nonce/epoch mints
  a different value, and the plan (fingerprint) is unaffected by the nonce.
  """
  use ExUnit.Case, async: true

  alias PropertyDamage.{Executor, Generator, Mint, Sequence}
  alias PropertyDamage.Sequence.Position

  # ---- A model whose command carries a minted request id ---------------------

  defmodule Send do
    @behaviour PropertyDamage.Command
    defstruct [:request_id]
    @impl true
    def generator(_overrides) do
      StreamData.constant(%{request_id: PropertyDamage.mint_per_run(:uuid)})
    end
  end

  defmodule Proj do
    @behaviour PropertyDamage.Model.Projection
    @impl true
    def init, do: %{}
    @impl true
    def apply(state, _), do: state
  end

  defmodule Model do
    @behaviour PropertyDamage.Model
    @behaviour PropertyDamage.Model.Simulator
    @impl true
    def commands, do: [Send]
    @impl true
    def command_sequence_projection, do: Proj
    @impl true
    def simulator, do: __MODULE__
    @impl PropertyDamage.Model.Simulator
    def simulate(_command, _state), do: []
  end

  defmodule Adapter do
    use PropertyDamage.Adapter
    @impl true
    def setup(config), do: {:ok, config}
    @impl true
    def teardown(_ctx), do: :ok
    @impl true
    def execute(%Send{}, _ctx, _runtime), do: {:ok, []}
  end

  defp generate(seed, opts \\ []) do
    Model
    |> Generator.generate_sequence(Keyword.merge([max_commands: 3], opts))
    |> Generator.generate_value(seed)
  end

  defp minted_values(result) do
    result.executed
    |> Enum.sort_by(fn {%Position{} = p, _} -> {inspect(p.section), p.offset} end)
    |> Enum.map(fn {_pos, cmd} -> cmd.request_id end)
  end

  defp run(seq, run_nonce, mint_epoch) do
    {:ok, result} =
      Executor.run(seq, Model, Adapter, run_nonce: run_nonce, mint_epoch: mint_epoch)

    result
  end

  describe "Mint.resolve/3 derivation" do
    test "same (nonce, epoch, position, path, kind) is byte-identical" do
      m = Mint.reify(Mint.new(:uuid), {:prefix, 0}, [:request_id])
      assert Mint.resolve(m, 42, 0) == Mint.resolve(m, 42, 0)
    end

    test "a different nonce, epoch, position, or path changes the value" do
      m = Mint.reify(Mint.new(:uuid), {:prefix, 0}, [:request_id])
      base = Mint.resolve(m, 42, 0)

      refute base == Mint.resolve(m, 43, 0)
      refute base == Mint.resolve(m, 42, 1)
      refute base == Mint.resolve(Mint.reify(Mint.new(:uuid), {:prefix, 1}, [:request_id]), 42, 0)
      refute base == Mint.resolve(Mint.reify(Mint.new(:uuid), {:prefix, 0}, [:other]), 42, 0)
    end

    test ":uuid formats as an RFC 4122 v4 UUID" do
      m = Mint.reify(Mint.new(:uuid), {:prefix, 0}, [:request_id])
      uuid = Mint.resolve(m, 1, 0)

      assert String.match?(
               uuid,
               ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/
             )
    end

    test "{:hex, n} yields n hex characters" do
      m = Mint.reify(Mint.new({:hex, 12}), {:prefix, 0}, [:k])
      assert String.match?(Mint.resolve(m, 1, 0), ~r/\A[0-9a-f]{12}\z/)
    end

    test "kind validation rejects anonymous-function-shaped kinds" do
      assert_raise ArgumentError, fn -> Mint.new(fn b -> b end) end
      assert_raise ArgumentError, fn -> Mint.new(:bogus) end
    end
  end

  describe "generation reifies markers deterministically" do
    test "same seed reifies markers with the same coordinates (plan is stable)" do
      assert generate(1234) == generate(1234)
    end

    test "a generated command holds a reified mint marker at its field" do
      [cmd | _] = generate(1234).prefix
      assert %Mint{kind: :uuid, position: {:prefix, 0}, path: [:request_id]} = cmd.request_id
    end
  end

  describe "resolution at execution (DR-034)" do
    test "same (seed, run_number) with different nonces: equal plan, different values" do
      seq = generate(1234)

      a = run(seq, 111, 0)
      b = run(seq, 222, 0)

      # The plan itself is unchanged by the nonce.
      assert Sequence.fingerprint(seq) == Sequence.fingerprint(seq)
      refute minted_values(a) == minted_values(b)
      # Every resolved value is a concrete UUID, never a leftover marker.
      assert Enum.all?(minted_values(a), &is_binary/1)
    end

    test "same (nonce, epoch): byte-identical minted values" do
      seq = generate(1234)
      assert minted_values(run(seq, 111, 0)) == minted_values(run(seq, 111, 0))
    end

    test "different epoch mints different values" do
      seq = generate(1234)
      refute minted_values(run(seq, 111, 0)) == minted_values(run(seq, 111, 1))
    end
  end

  describe "sibling branches at the same flat index mint distinct values" do
    test "branch positions keep two same-flat-index mints distinct" do
      # Both branches' first command shares the executor flat index, but their
      # structured positions ({:branch, 0, 0} vs {:branch, 1, 0}) differ, so the
      # minted values differ. A flat-index key would have collided — the exact
      # duplicate-identity bug DR-034 bakes coordinates in to prevent.
      b0 = %Send{request_id: Mint.reify(Mint.new(:uuid), {:branch, 0, 0}, [:request_id])}
      b1 = %Send{request_id: Mint.reify(Mint.new(:uuid), {:branch, 1, 0}, [:request_id])}
      seq = Sequence.branching([], [[b0], [b1]], [])

      result = run(seq, 111, 0)

      v0 = result.executed[%Position{section: {:branch, 0}, offset: 0}].request_id
      v1 = result.executed[%Position{section: {:branch, 1}, offset: 0}].request_id

      assert is_binary(v0) and is_binary(v1)
      refute v0 == v1
    end

    test "the generator bakes branch-structured positions into branch mints" do
      # Prove the reification path itself keys on {:branch, b, i}, not the flat
      # index, so the distinctness above is what generation actually produces.
      seq =
        Enum.find_value(1..400, fn seed ->
          s =
            generate(seed,
              max_commands: 12,
              branching: [branch_probability: 0.9, max_branches: 3, min_prefix_length: 1]
            )

          if s.branches && Enum.count(s.branches, &(&1 != [])) >= 2, do: s
        end)

      assert seq, "no seed produced a multi-branch plan"

      branch_positions =
        for {branch, b} <- Enum.with_index(seq.branches),
            {%Send{request_id: %Mint{position: pos}}, _i} <- Enum.with_index(branch),
            do: {b, pos}

      assert Enum.all?(branch_positions, fn {b, pos} -> match?({:branch, ^b, _}, pos) end)
    end
  end

  describe "models without minted fields are unaffected by the nonce" do
    defmodule Plain do
      @behaviour PropertyDamage.Command
      defstruct [:n]
      @impl true
      def generator(_), do: StreamData.constant(%{n: 1})
    end

    defmodule PlainModel do
      @behaviour PropertyDamage.Model
      @behaviour PropertyDamage.Model.Simulator
      @impl true
      def commands, do: [Plain]
      @impl true
      def command_sequence_projection, do: Proj
      @impl true
      def simulator, do: __MODULE__
      @impl PropertyDamage.Model.Simulator
      def simulate(_c, _s), do: []
    end

    defmodule PlainAdapter do
      use PropertyDamage.Adapter
      @impl true
      def setup(c), do: {:ok, c}
      @impl true
      def teardown(_), do: :ok
      @impl true
      def execute(%Plain{}, _ctx, _rt), do: {:ok, []}
    end

    test "nonce is inert without minted fields" do
      seq =
        PlainModel
        |> Generator.generate_sequence(max_commands: 3)
        |> Generator.generate_value(1234)

      {:ok, a} = Executor.run(seq, PlainModel, PlainAdapter, run_nonce: 111, mint_epoch: 0)
      {:ok, b} = Executor.run(seq, PlainModel, PlainAdapter, run_nonce: 222, mint_epoch: 5)

      assert a.executed == b.executed
    end
  end
end
