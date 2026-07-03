defmodule PropertyDamage.Audit do
  @moduledoc """
  Proves a model's generation is a pure function of the seed (DR-037).

  Generation is meant to be a **pure function of `(seed, model, generation
  opts)`**: `PropertyDamage.Generator.generate_value/3` realizes every value
  through `StreamData.seeded/2` at a constant size, so the same seed always
  yields the same plan. All nondeterminism — the clock, `:rand`,
  `System.unique_integer/1`, server-assigned ids, environment — belongs behind
  an execution-time seam (an adapter reifying a seeded relative offset, or
  `mint_per_run/1`), never inside a generator / `when:` / `with:` predicate /
  `command_sequence_projection` / simulator.

  Nothing enforces that contract for *user* code. A generator that reads
  `DateTime.utc_now/0` or `UUID.uuid4/0` silently breaks it: `mix ... seed: N`
  stops reproducing, and `PropertyDamage.RunComparison`'s fingerprint guard
  refuses every comparison for that model (two "same seed" captures no longer
  generate the same plan). This audit is the actionable, generation-only early
  warning for exactly the failure the comparability guard reports cryptically.

  ## What it does

  For each of N deterministically chosen seeds it realizes the model's
  generated `%PropertyDamage.Sequence{}` **twice at the same seed** through the
  seeded path and asserts the two are structurally equal (`==`). Post-DR-036
  placeholder and mint-marker identities are deterministic, so raw equality is
  honest for pure models — including `external()`- and `mint_per_run`-using
  ones. On divergence it localizes the first differing command position and its
  differing fields and points at `guides/deterministic_generation.md`.

  It is generation-only: no adapter, no SUT, no execution. It never resolves
  `mint_per_run` markers or placeholders (that is a concrete-phase concern);
  those are position-stamped symbolic structs and therefore part of the
  deterministic plan.

  ## Relationship to the run-comparison guard

  The audit proves a model's generation is pure (dev/CI-time, N seeds). The
  fingerprint guard in `PropertyDamage.RunComparison` (DR-035) refuses to
  compare two captured runs whose plans differ (runtime, per comparison). An
  impure model fails the audit and, equivalently, can never satisfy the guard.

  ## Usage

      PropertyDamage.audit(MyApp.Model)
      PropertyDamage.audit(MyApp.Model, seeds: 500, max_commands: 40)
      PropertyDamage.audit(MyApp.Model, branching: [branch_probability: 0.3])

  `mix pd.audit MyApp.Model` wraps this for CI gating.
  """

  alias PropertyDamage.{Generator, Sequence}
  alias PropertyDamage.Sequence.Position

  @default_seeds 100

  @typedoc """
  A localized description of the first divergence found between two same-seed
  generations. `position` names where in the sequence it occurred; `message` is
  an actionable, human-readable explanation.
  """
  @type divergence :: %{
          required(:position) => term(),
          required(:message) => String.t(),
          optional(:command_a) => struct(),
          optional(:command_b) => struct(),
          optional(:fields) => %{atom() => {term(), term()}},
          optional(:structural) => boolean()
        }

  @type result :: :ok | {:error, %{seed: integer(), divergence: divergence()}}

  @doc """
  Audit that `model`'s generation is a pure function of the seed.

  ## Options

  - `:seeds` — a positive integer count (audits seeds `0..count-1`) or an
    explicit list of integer seeds. Must itself be deterministic; defaults to
    `#{@default_seeds}`.
  - `:max_commands` — threaded into `generate_sequence/2` (default framework
    value applies otherwise).
  - `:branching` — branching options threaded into `generate_sequence/2`, so
    branch generation is exercised, not only the linear path.
  - `:external_markers` — threaded through for models relying on custom
    external markers.

  Returns `:ok` when every audited seed generates identically twice, or
  `{:error, %{seed: seed, divergence: divergence}}` for the first seed that
  diverges.
  """
  @spec run(module(), keyword()) :: result()
  def run(model, opts \\ []) do
    opts = PropertyDamage.Options.validate_audit!(opts)
    seeds = normalize_seeds(Keyword.get(opts, :seeds, @default_seeds))
    gen_opts = Keyword.take(opts, [:max_commands, :branching, :external_markers])

    # Build the generator once (as a real run does) and reuse it across seeds;
    # it is a pure, lazy StreamData value, so reuse is correct.
    generator = Generator.generate_sequence(model, gen_opts)

    audit_seeds(generator, seeds)
  end

  defp normalize_seeds(count) when is_integer(count) and count > 0,
    do: Enum.to_list(0..(count - 1))

  defp normalize_seeds(list) when is_list(list), do: list

  defp audit_seeds(_generator, []), do: :ok

  defp audit_seeds(generator, [seed | rest]) do
    # Realize twice at the SAME seed via the seeded path (never Enum.at on the
    # raw stream, which would reseed from the wall clock and defeat the audit).
    seq1 = Generator.generate_value(generator, seed)
    seq2 = Generator.generate_value(generator, seed)

    if seq1 == seq2 do
      audit_seeds(generator, rest)
    else
      {:error, %{seed: seed, divergence: localize(seq1, seq2)}}
    end
  end

  # ============================================================================
  # Divergence localization (rendered directly; no Diff/RunComparison — Diff is
  # deleted and RunComparison compares executed traces, not generated sequences)
  # ============================================================================

  @doc false
  @spec localize(Sequence.t(), Sequence.t()) :: divergence()
  def localize(seq1, seq2) do
    flat1 = flatten(seq1)
    flat2 = flatten(seq2)
    positions1 = Enum.map(flat1, &elem(&1, 0))
    positions2 = Enum.map(flat2, &elem(&1, 0))

    if positions1 != positions2 do
      structural_divergence(positions1, positions2)
    else
      first_command_divergence(flat1, flat2) || registry_divergence()
    end
  end

  # Flatten a sequence into ordered {position, command} pairs using the same
  # structured position scheme the generator mints against (DR-021).
  defp flatten(%Sequence{prefix: prefix, branches: branches, suffix: suffix}) do
    with_positions(prefix, &Position.prefix/1) ++
      branch_positions(branches) ++
      with_positions(suffix, &Position.suffix/1)
  end

  defp branch_positions(nil), do: []

  defp branch_positions(branches) do
    branches
    |> Enum.with_index()
    |> Enum.flat_map(fn {branch, b} ->
      with_positions(branch, &Position.branch(b, &1))
    end)
  end

  defp with_positions(commands, pos_fun) do
    Enum.with_index(commands, fn cmd, i -> {pos_fun.(i), cmd} end)
  end

  defp first_command_divergence(flat1, flat2) do
    flat1
    |> Enum.zip(flat2)
    |> Enum.find_value(fn {{pos, c1}, {_pos, c2}} ->
      if c1 == c2, do: false, else: command_divergence(pos, c1, c2)
    end)
  end

  defp command_divergence(pos, %m1{} = c1, %m2{} = c2) when m1 != m2 do
    %{
      position: pos,
      command_a: c1,
      command_b: c2,
      fields: %{},
      message: module_message(pos, m1, m2)
    }
  end

  defp command_divergence(pos, c1, c2) do
    fields = field_diff(c1, c2)

    %{
      position: pos,
      command_a: c1,
      command_b: c2,
      fields: fields,
      message: field_message(pos, c1, fields)
    }
  end

  defp field_diff(c1, c2) do
    m1 = Map.from_struct(c1)
    m2 = Map.from_struct(c2)

    for {k, v1} <- m1, v2 = Map.get(m2, k), v1 != v2, into: %{} do
      {k, {v1, v2}}
    end
  end

  defp structural_divergence(positions1, positions2) do
    first = first_position_mismatch(positions1, positions2)

    %{
      position: first,
      structural: true,
      message:
        "two identical-seed generations produced different sequence structure " <>
          "(first divergence near #{format_pos(first)}; #{length(positions1)} vs " <>
          "#{length(positions2)} commands) — generation is not a pure function of the " <>
          "seed. #{guidance()}"
    }
  end

  defp first_position_mismatch(positions1, positions2) do
    positions1
    |> Enum.zip(positions2)
    |> Enum.find_value(:sequence_length, fn {a, b} -> if a != b, do: a end)
  end

  # Fallback: commands are identical yet the whole sequences are not, so the
  # derived registry differs. Post-DR-036 this signals a framework-level
  # regression of deterministic placeholder identity rather than user impurity.
  defp registry_divergence do
    %{
      position: :registry,
      message:
        "two identical-seed generations produced identical commands but a differing " <>
          "derived placeholder registry — non-deterministic placeholder identity, a " <>
          "framework-level regression of DR-036. #{guidance()}"
    }
  end

  # ============================================================================
  # Messages
  # ============================================================================

  defp module_message(pos, m1, m2) do
    "at #{format_pos(pos)} two identical-seed generations selected different commands " <>
      "(#{inspect(m1)} vs #{inspect(m2)}) — a `when:`/`with:` predicate or the " <>
      "command_sequence_projection/simulator is likely reading the clock, `:rand`, or " <>
      "process state, changing command selection. #{guidance()}"
  end

  defp field_message(pos, %module{}, fields) do
    field_names = fields |> Map.keys() |> Enum.map_join(", ", &inspect/1)

    "field(s) #{field_names} of #{inspect(module)} at #{format_pos(pos)} differ across two " <>
      "identical-seed generations — a generator (or `when:`/`with:`) is likely reading the " <>
      "clock, `:rand`, `System.unique_integer/1`, or process state. #{guidance()}"
  end

  defp guidance do
    "Model time as a seeded relative offset reified in the adapter, and client-minted " <>
      "unique values via mint_per_run/1; see guides/deterministic_generation.md."
  end

  defp format_pos(%Position{} = pos), do: Position.describe(pos)
  defp format_pos(:sequence_length), do: "the end of the shorter sequence"
  defp format_pos(:registry), do: "the placeholder registry"
  defp format_pos(other), do: inspect(other)
end
