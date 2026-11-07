# Writes the shrink-work fixture the shrink parity test compares against.
#
# Run from the repository root, so that `test/support` is compiled:
#
#     MIX_ENV=test mix run test/fixtures/shrink_parity/generate.exs
#
# An optional argument names another output file, which is how a run is
# compared without touching the tracked fixture:
#
#     MIX_ENV=test mix run test/fixtures/shrink_parity/generate.exs /tmp/iterations_b.exs
alias PropertyDamage.Test.ShrinkParity

path =
  case System.argv() do
    [file | _] -> Path.expand(file)
    [] -> ShrinkParity.fixture_path()
  end

observed = ShrinkParity.observe_all()
File.write!(path, ShrinkParity.encode(observed))

for {name, seeds} <- Enum.sort(observed) do
  failing = Enum.count(seeds, fn {_seed, observation} -> observation != nil end)
  IO.puts("#{name}: #{length(seeds)} seeds, #{failing} failing")
end

IO.puts("wrote #{path}")
