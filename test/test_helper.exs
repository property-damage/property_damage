# Tests tagged :known_defect describe a documented defect and were checked in
# before its fix. The default run excludes them; run them with
# `mix test --include known_defect`. The change that fixes the defect removes
# the tag.
ExUnit.start(exclude: [:known_defect])
