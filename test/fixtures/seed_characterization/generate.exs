# Writes the golden files the seed characterization test compares against.
#
# Run from the repository root, so that `test/support` is compiled:
#
#     MIX_ENV=test mix run test/fixtures/seed_characterization/generate.exs
#
# An optional argument names another output directory, which is how two runs
# are compared without touching the tracked files:
#
#     MIX_ENV=test mix run test/fixtures/seed_characterization/generate.exs /tmp/golden_b
alias PropertyDamage.Test.SeedCharacterization, as: S

out_dir =
  case System.argv() do
    [dir | _] -> Path.expand(dir)
    [] -> S.fixture_dir()
  end

File.mkdir_p!(out_dir)

for name <- S.case_names() do
  rendered = for seed <- S.seeds(name), do: {seed, S.render_run(name, seed)}
  path = Path.join(out_dir, "#{name}.exs")
  File.write!(path, S.encode(rendered))
  fails = Enum.count(rendered, fn {_seed, run} -> run.outcome == :fail end)
  IO.puts("#{path}: #{length(rendered)} seeds, #{fails} failing")
end
