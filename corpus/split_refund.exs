# Two refunds that split one refund (a, then b) credit less than one refund of
# a + b: the second refund of a split pair is credited one unit short. The
# smallest failing plan pays 2, then refunds 2 as a refund of 1 followed by a
# refund of 1, and the totals of the two paths differ by one.
#
# Skipped: the framework compares two command paths only across two or more
# targets, each running its own path (see the path equivalence guide). The
# corpus engine passes one target to the run, and a one-target run checks the
# model's properties but compares nothing. The model and the adapter cannot
# supply the second target, so an engine that passes two targets measures this
# entry.
%PropertyDamage.Corpus.Entry{
  name: "split_refund",
  skip:
    "it compares two command paths across two targets, and the current engine passes one target to the run"
}
