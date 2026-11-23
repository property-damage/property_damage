# Tests tagged :known_defect describe a documented defect and were checked in
# before its fix. The default run excludes them; run them with
# `mix test --include known_defect`. The change that fixes the defect removes
# the tag.
#
# Tests tagged :patched_stream_data need StreamData 1.4.0 with the patch in
# test/support/stream_data_patch/. Before the suite starts, the line below
# patches a copy of deps/stream_data into _build/test/stream_data_patch/ (it
# needs the `patch` executable), compiles it and loads it from a copy of the
# stream_data ebin directory there. The released dependency, mix.lock and dev
# or prod builds stay untouched. A behavior probe then decides whether the
# patched module is live; if not, the run excludes the tag and ExUnit reports
# those tests as excluded. Set PD_SKIP_STREAM_DATA_PATCH=1 to run against the
# released StreamData. On CI (CI=true) a failed apply stops the run, so the
# tagged tests cannot drop out of the count unnoticed.
alias PropertyDamage.Test.PatchedStreamData

on_ci? = System.get_env("CI") == "true"

case PatchedStreamData.load() do
  {:error, reason} when on_ci? -> raise "StreamData patch not applied: #{reason}"
  {:error, reason} -> IO.puts(:stderr, "StreamData patch not applied: #{reason}")
  _loaded_or_skipped -> :ok
end

stream_data_exclusions = if PatchedStreamData.active?(), do: [], else: [:patched_stream_data]

ExUnit.start(exclude: [:known_defect | stream_data_exclusions])
