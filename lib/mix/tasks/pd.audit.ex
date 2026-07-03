defmodule Mix.Tasks.Pd.Audit do
  @moduledoc """
  Audits that a PropertyDamage model's generation is a pure function of the seed.

  Generation MUST be deterministic in `(seed, model, generation opts)`: all
  nondeterminism (the clock, `:rand`, client-minted ids, environment) belongs
  behind an execution-time seam, never inside a generator, a `when:`/`with:`
  predicate, the command_sequence_projection, or the simulator. This task
  realizes the model's generated sequence twice at each of N seeds and checks
  the two are structurally identical, so impurity is caught at dev/CI time
  before it breaks `seed: N` reproduction and `PropertyDamage.RunComparison`'s
  fingerprint guard.

  It gates CI: on divergence it prints the first diverging seed and the first
  differing command position/fields, then exits non-zero.

  ## Usage

      mix pd.audit MyApp.Model
      mix pd.audit MyApp.Model --seeds 500 --max-commands 40
      mix pd.audit MyApp.Model --branching --branch-probability 0.3

  ## Options

      --seeds N               Number of seeds to audit (audits 0..N-1). Default 100.
      --max-commands N        Max commands per generated sequence.
      --branching             Exercise branching generation (not just linear).
      --branch-probability F  Branch-point probability (implies --branching).
      --max-branches N        Maximum parallel branches (implies --branching).
      --max-branch-length N   Maximum commands per branch (implies --branching).

  See `guides/deterministic_generation.md` for the deterministic patterns that
  keep generation pure (seeded relative time offsets, `mint_per_run/1`,
  `external/0`).
  """

  use Mix.Task

  alias PropertyDamage.Sequence.Position

  @shortdoc "Audit that a model's generation is a pure function of the seed"

  @impl true
  def run(args) do
    args |> exec() |> halt_on_error()
  end

  # Testable seam: `run/1` translates an `:error` status into a non-zero
  # `System.halt`, so the decision logic can be exercised in-process without
  # killing the VM (mirrors `mix pd.validate`).
  @doc false
  @spec exec([String.t()]) :: :ok | :error
  def exec(args) do
    {opts, argv, _} =
      OptionParser.parse(args,
        strict: [
          seeds: :integer,
          max_commands: :integer,
          branching: :boolean,
          branch_probability: :float,
          max_branches: :integer,
          max_branch_length: :integer
        ]
      )

    dispatch(argv, opts)
  end

  defp dispatch([model_str], opts) do
    Mix.Task.run("compile", [])
    model = parse_module(model_str)

    if Code.ensure_loaded?(model) do
      run_audit(model, opts)
    else
      print_color(:red, "ERROR: Model module #{inspect(model)} does not exist\n")
      print_hint("Make sure the module is defined and the project is compiled.")
      :error
    end
  end

  defp dispatch([], _opts) do
    print_usage()
    :ok
  end

  defp dispatch(_argv, _opts) do
    print_color(:red, "Error: Expected exactly 1 argument (the model module)\n")
    print_usage()
    :error
  end

  defp run_audit(model, opts) do
    audit_opts = build_audit_opts(opts)

    IO.puts("\n")
    print_header("PropertyDamage Determinism Audit")
    IO.puts("")
    IO.puts("Model:    #{inspect(model)}")
    IO.puts("Seeds:    #{Keyword.get(audit_opts, :seeds, 100)}")
    report_gen_opts(audit_opts)
    IO.puts("")

    case PropertyDamage.audit(model, audit_opts) do
      :ok ->
        print_color(:green, "AUDIT PASSED: generation is a pure function of the seed\n")
        audit_projection_purity(model, audit_opts)

      {:error, %{seed: seed, divergence: divergence}} ->
        print_divergence(seed, divergence)
        :error
    end
  rescue
    e ->
      IO.puts("")
      print_color(:red, "AUDIT FAILED\n")
      IO.puts(Exception.message(e))
      :error
  end

  # P8 / DR-040: after generation purity, check that projection apply/2 is a pure
  # function of its inputs (folds each plan twice and compares). Returns :ok /
  # :error so the task's exit status gates CI on either failure.
  defp audit_projection_purity(model, audit_opts) do
    case PropertyDamage.audit_projections(model, audit_opts) do
      :ok ->
        print_color(:green, "PROJECTION AUDIT PASSED: apply/2 is a pure function of its inputs\n")
        :ok

      {:error, %{seed: seed, modules: modules}} ->
        IO.puts("")
        print_color(:red, "PROJECTION AUDIT FAILED at seed #{seed}\n")

        IO.puts(
          "These projections folded to different state on a second pass (non-pure apply/2):"
        )

        Enum.each(modules, fn module -> IO.puts("  - #{inspect(module)}") end)

        print_hint(
          "A projection's apply/2 must depend only on (state, event). Move any clock, " <>
            "counter, or environment read behind an execution-time seam. See " <>
            "guides/deterministic_generation.md."
        )

        :error
    end
  end

  # Translate flat CLI flags into the keyword shape PropertyDamage.audit/2 wants.
  # Any branching-related flag implies branching is on.
  defp build_audit_opts(opts) do
    branching_keys = [:branch_probability, :max_branches, :max_branch_length]
    branching_opts = Keyword.take(opts, branching_keys)
    branching? = Keyword.get(opts, :branching, false) or branching_opts != []

    []
    |> maybe_put(:seeds, Keyword.get(opts, :seeds))
    |> maybe_put(:max_commands, Keyword.get(opts, :max_commands))
    |> maybe_put(:branching, if(branching?, do: branching_opts, else: nil))
  end

  defp maybe_put(kw, _key, nil), do: kw
  defp maybe_put(kw, key, value), do: Keyword.put(kw, key, value)

  defp report_gen_opts(audit_opts) do
    if max = Keyword.get(audit_opts, :max_commands), do: IO.puts("Max cmds: #{max}")

    case Keyword.get(audit_opts, :branching) do
      nil -> IO.puts("Mode:     linear")
      branching -> IO.puts("Mode:     branching #{inspect(branching)}")
    end
  end

  defp print_divergence(seed, divergence) do
    IO.puts("")
    print_color(:red, "AUDIT FAILED: generation is NOT a pure function of the seed\n")
    IO.puts("")
    IO.puts("First diverging seed: #{seed}")
    IO.puts("Position:             #{format_position(divergence.position)}")

    case Map.get(divergence, :fields) do
      fields when is_map(fields) and map_size(fields) > 0 ->
        IO.puts("Differing fields:")

        for {field, {a, b}} <- fields do
          IO.puts("  #{inspect(field)}: #{inspect(a)} vs #{inspect(b)}")
        end

      _ ->
        :ok
    end

    IO.puts("")
    print_color(:yellow, divergence.message <> "\n")
  end

  defp format_position(%Position{} = pos), do: Position.describe(pos)
  defp format_position(other), do: inspect(other)

  defp halt_on_error(:error), do: System.halt(1)
  defp halt_on_error(_), do: :ok

  defp parse_module(string) do
    string
    |> String.replace(~r/^Elixir\./, "")
    |> then(&("Elixir." <> &1))
    |> String.to_atom()
  end

  defp print_header(text) do
    border = String.duplicate("=", String.length(text) + 4)
    IO.puts(border)
    IO.puts("  #{text}")
    IO.puts(border)
  end

  defp print_hint(text), do: print_color(:cyan, "    Hint: #{text}\n")

  defp print_color(color, text), do: IO.puts([color_code(color), text, IO.ANSI.reset()])

  defp color_code(:red), do: IO.ANSI.red()
  defp color_code(:green), do: IO.ANSI.green()
  defp color_code(:yellow), do: IO.ANSI.yellow()
  defp color_code(:cyan), do: IO.ANSI.cyan()

  defp print_usage do
    IO.puts("""

    Usage: mix pd.audit MODEL [OPTIONS]

    Arguments:
      MODEL     The model module (e.g., MyApp.TestModel)

    Options:
      --seeds N               Number of seeds to audit (0..N-1). Default 100.
      --max-commands N        Max commands per generated sequence.
      --branching             Exercise branching generation.
      --branch-probability F  Branch-point probability (implies --branching).
      --max-branches N        Maximum parallel branches (implies --branching).
      --max-branch-length N   Maximum commands per branch (implies --branching).

    Examples:
      mix pd.audit MyApp.TestModel
      mix pd.audit MyApp.TestModel --seeds 500 --max-commands 40
      mix pd.audit MyApp.TestModel --branching --branch-probability 0.3
    """)
  end
end
