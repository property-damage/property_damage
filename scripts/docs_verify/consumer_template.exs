# Scaffolds and caches the "honest stranger" consumer mix project.
#
# A consumer project depends on PropertyDamage via a PATH dependency on the
# worktree checkout (no ambient assumptions from the repo's own mix context). It
# is scaffolded and compiled ONCE, cached under tmp/ keyed on the worktree's
# mix.lock + mix.exs, and reused across runs. Per-doc working dirs are cheap
# symlink overlays on this template (see DocsVerify.DocRunner).
#
# Every mix subprocess runs with HEX_HOME pointed at the gate's own scratch dir
# so a gate run never rewrites the workstation's shared ~/.hex/hex.config (which
# hex corrupts on token refresh). This is also more faithful to the stranger env.
defmodule DocsVerify.ConsumerTemplate do
  @doc """
  Ensure a compiled consumer template exists. Returns
  `{status, template_dir, ebin_paths}` where status is `:cache_hit` or
  `:cache_miss`.
  """
  def ensure(worktree_root, tmp_root, hex_home) do
    key = cache_key(worktree_root)
    dir = Path.join(tmp_root, "template-" <> key)
    stamp = Path.join(dir, ".pd_compiled")

    if File.exists?(stamp) do
      {:cache_hit, dir, ebin_paths(dir)}
    else
      File.rm_rf!(dir)
      File.mkdir_p!(Path.join(dir, "lib"))
      File.write!(Path.join(dir, "mix.exs"), mix_exs(worktree_root))

      env = [{"HEX_HOME", hex_home}, {"MIX_ENV", "dev"}]
      run_mix!(dir, ["deps.get"], env)
      run_mix!(dir, ["compile"], env)

      File.write!(stamp, "ok\n")
      {:cache_miss, dir, ebin_paths(dir)}
    end
  end

  @doc "Absolute ebin paths of the compiled template and all its deps."
  def ebin_paths(dir) do
    dir
    |> Path.join("_build/dev/lib/*/ebin")
    |> Path.wildcard()
    |> Enum.map(&Path.expand/1)
  end

  defp cache_key(worktree_root) do
    lock = read_or_empty(Path.join(worktree_root, "mix.lock"))
    mixexs = read_or_empty(Path.join(worktree_root, "mix.exs"))
    template = mix_exs(worktree_root)

    :crypto.hash(:sha256, lock <> "\0" <> mixexs <> "\0" <> template)
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  defp read_or_empty(path) do
    case File.read(path) do
      {:ok, data} -> data
      _ -> ""
    end
  end

  defp mix_exs(worktree_root) do
    """
    defmodule DocConsumer.MixProject do
      use Mix.Project

      def project do
        [
          app: :doc_consumer,
          version: "0.0.0",
          elixir: "~> 1.17",
          deps: deps()
        ]
      end

      def application do
        [extra_applications: [:logger]]
      end

      defp deps do
        [
          {:property_damage, path: #{inspect(worktree_root)}},
          {:stream_data, "~> 1.0"}
        ]
      end
    end
    """
  end

  defp run_mix!(dir, args, env) do
    {out, status} =
      System.cmd("mix", args, cd: dir, env: env, stderr_to_stdout: true)

    if status != 0 do
      raise """
      consumer template scaffold failed: mix #{Enum.join(args, " ")} (exit #{status})
      #{out}
      """
    end

    :ok
  end
end
