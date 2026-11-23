# DR-071: A Second Engine Draws Every Value Through StreamData from a Recording Source

**Status:** Accepted
**Date:** 2026-11-23

## Context

`PropertyDamage.Next` draws every value through an engine (DR-068), and its
shrinker edits the journal that the engine writes (DR-069). `Engine.Native`
gives PD's own descriptions (`integer/1`, `member_of/1`, `boolean/0`) entries
that PD fits and lowers itself. It stores any other StreamData value as a path
in StreamData's shrink tree, which the shrinker reaches by steering the public
`StreamData.check_all/3`.

That split leaves a nested value only partly in PD's hands. Take a refund
whose price is `fixed_map(amount: integer(1..balance), currency:
member_of([:base, :alt]))`. `Engine.Native` stores the whole map as one path.
When an earlier payment shrinks and the balance drops, the stored path is
walked on the new tree, so the amount is not fitted to the new range, and the
site lands on the kept list (DR-068, amendment).

StreamData draws every value from a `:rand` state. If PD could hand
StreamData a state of its own and see each range draw, PD could record every
part of a nested value and fit each part on a rebuild. StreamData 1.4.0 does
not allow that: it splits states and draws ranges in private functions that
call `:rand` directly. A second engine therefore needs a change to StreamData.

This record covers that engine, the change to StreamData it needs, and what
the corpus shows when both engines run the same entries.

## Decision

1. **The engine.** `PropertyDamage.Next.Engine.StreamDataSource`
   (`lib/property_damage/next/engine/stream_data_source.ex`) draws every
   generator through StreamData, with a `:rand` state it controls. PD's
   descriptions are drawn this way too: `Gen.to_stream_data/1` converts
   `integer/1`, `member_of/1` and `boolean/0` first, so an integer field and
   a nested map give the same kind of entry. Every draw uses the size
   `Steering.size/0`, as `Engine.Native` does.

2. **The source.** The engine seeds its `:rand` state from
   `Journal.key_seed/2`, so each journal key has its own generator. A
   position names one draw: `{split_path, counter}`. The counter counts the
   draws and splits made on one state. The split path lists the counter of
   each split that led from the root state to this one. When StreamData
   splits a state, the child starts at counter 0 under the split's position.
   When StreamData asks for an integer between two bounds, the source
   answers and records `{value, lo, hi}` at the position.

3. **The entry.** The entry is `{:source, value, positions}`. `positions`
   lists each recorded position with its `{value, lo, hi}`. A draw made
   inside a split sorts before the draws its parent makes after the split.
   The entry holds integers, lists and tuples only. For example,
   `integer(1..10)` that drew 7 records `{:source, 7, [{{[0], 0}, {7, 1,
   10}}]}`. `member_of([:a, :b, :c])` draws the index of its member, so a
   draw of `:c` records `{:source, :c, [{{[0], 0}, {2, 0, 2}}]}`.

4. **The fit rule.** On a rebuild, the source answers each position the
   draw visits again from the entry. It reads the stored value, the stored
   upper bound, and the bounds StreamData asks for now:
   - If the stored value sat on the stored upper bound and the upper bound
     moved, the source answers the new upper bound.
   - Otherwise, if the stored value lies outside the new bounds, the source
     answers the nearer bound.
   - Otherwise it answers the stored value.

   A position the entry does not hold, such as an element of a list that
   grew, is drawn afresh from the key's generator. A stored position that
   the draw no longer visits is dropped from the new entry. The same
   journal, key, generator and seed give the same value and entry in any VM.

5. **Dependent generators.** The engine exports `fits_dependent?/1`, which
   answers `true`. A generator that a `from/2` function or a dependent
   assign returns is drawn the same way and fitted part by part, so
   generation neither warns nor raises about such a site, and the kept list
   stays empty for it (DR-068, amendment).

6. **The StreamData change is a patch file applied in the test environment
   only.** `test/support/stream_data_patch/stream_data_1.4.0.patch` adds two
   clauses to `deps/stream_data/lib/stream_data.ex` and changes no existing
   line:
   - `split_seed/1`: a `:rand` state whose algorithm map carries `:split`
     splits itself.
   - `uniform_in_range/3`: a `:rand` state whose algorithm map carries
     `:uniform_range` receives both bounds of the range draw.

   Every other state behaves exactly as before. PD keeps no fork and no git
   dependency of StreamData, and `mix.lock` is unchanged. Dev and prod
   builds use the released StreamData.

7. **How the patch is applied.** `test/test_helper.exs` calls
   `PropertyDamage.Test.PatchedStreamData.load/0`
   (`test/support/patched_stream_data.ex`) before `ExUnit.start/1`:
   1. The `patch` executable writes the released source plus the patch to
      `_build/test/stream_data_patch/stream_data.ex`, with `--fuzz=0`. A
      patch that does not apply exactly fails.
   2. `Code.compile_file/1` compiles that copy.
   3. The loader copies the released `stream_data` ebin directory next to
      it, overwrites the beams of the patched modules, reloads them from
      there, and puts that directory first on the code path. A fresh VM that
      a test starts from `:code.which(StreamData)` then finds both the
      patched beams and `stream_data.app`.
   4. A probe draws one integer through a state that carries the seams. If
      the seam did not run, the run excludes the tests tagged
      `:patched_stream_data`, and ExUnit reports them as excluded.

   CI runs the apply step inside `mix test`, with no separate job. On CI
   (`CI=true`), a failed apply raises and stops the run, so the tagged tests
   cannot drop out of the count unnoticed. `PD_SKIP_STREAM_DATA_PATCH=1`
   runs the suite against the released StreamData.

8. **The corpus runs the second engine under `MIX_ENV=test`.** `mix
   pd.corpus --both-engines` runs each `corpus/next` entry once per engine
   and adds an engine column to the table and the saved table
   (`lib/mix/tasks/pd.corpus.ex`, `lib/mix/tasks/pd.corpus/table.ex`). The
   rows of the second engine come from `PropertyDamage.Corpus.Engine.NextSource`
   (`lib/mix/tasks/pd.corpus/engine/next_source.ex`), which loads the patched
   StreamData through the test-support loader. In any other environment, or
   with the patch skipped, the task exits 1 before it runs an entry and
   names the command to use: `MIX_ENV=test mix pd.corpus --dir corpus/next
   --both-engines`. Without the flag, the task runs as before.

9. **One more shrink move.** The shrinker (`lib/property_damage/next/shrinker.ex`)
   gains one clause for source entries. It lowers each recorded position,
   later positions first: it tries the position's lower bound, then bisects
   between the lower bound and the stored value. It reads each position
   again before each candidate, because an adoption can drop the position
   or move its bounds. Every candidate goes through the same adoption test
   as the other moves (DR-069, decision 3).

   The shrinker reads and edits positions only through the engine's
   functions `tag/0`, `positions/1` and `put_position/3`. Without them, the
   shrinker would have to know the entry's layout, and a change to that
   layout would break shrinking without a compile error in the engine.

10. **Journal format version 3.** A journal can now hold source entries. A
    PD that loads version 2 knows no `:source` tag: its loader does not
    create that atom before the safe decode, and its engines would not read
    such an entry. The format version therefore moves to 3, so such a PD
    refuses the journal with a message instead of misreading it. The loader
    refuses versions 1 and 2, and any other version, with a message that
    names the version found and the version it loads. The `:source` tag
    joins the entry tags whose atoms the loader creates before it decodes a
    journal in a fresh VM.

## Does the patch alone suffice?

**On the StreamData side, yes.** Every `corpus/next` entry runs on the second
engine with only the two clauses of the patch, and finds its bug on as many
seeds as on `Engine.Native` (every seed but one for `offset_refund`, on both
engines). No other
change to StreamData was needed: the applied copy differs from the released
source by exactly those two insertions.

**On the PD side, three more pieces were needed:** the engine itself, the
one shrinker clause of decision 9, and journal format version 3.

**No different or smaller seam showed up, but the two seams do not cover
every draw.** In StreamData 1.4.0, every range draw goes through
`uniform_in_range/3`, and every split goes through `split_seed/1`, with one
exception. `random_pseudofactors/2` calls `:rand.uniform_s/2` directly to
choose the level sizes of `tree/2`. `term/0`, `iodata/0` and `chardata/0`
build on `tree/2`. On this engine, such a draw comes from the key's
generator, so it is deterministic. The source does not record it, so the
engine cannot fit it and the shrinker cannot lower it. Such a draw can also
change on a replay. A fitted position does not advance the key's generator,
but a fresh draw does. So when a fresh range draw precedes a split on one
state, as a list's length precedes its elements, the replay hands the
elements different child generators. A `tree/2` level size drawn inside such
an element then changes, and the replay builds a different value. For
example, `list_of(tree(integer(0..9), &list_of/1), length: 2)` replays to a
different value on each of three seeds probed. No `corpus/next` entry and no
test draws `tree/2`, `term/0`, `iodata/0` or `chardata/0`.

**The fit rules differ from `Engine.Native` (DR-069, decision 4).**

| case | `Engine.Native` | this engine |
|---|---|---|
| `500` from `1..500`, range now `1..800` | 500 (kept) | 800 (follows the upper bound) |
| `9` from `5..9`, range now `1..20` | 9 (kept) | 20 (follows the upper bound) |
| `5` from `5..9`, range now `3..9` | 5, and the shrinker retries 3 once | 5, never 3 |
| `:usd` from `[:eur, :usd, :chf]`, list now `[:usd, :eur, :chf]` | `:usd` (kept by identity) | `:eur` (same index) |
| `:chf` from `[:eur, :usd, :chf]`, list now `[:eur, :usd, :chf, :gbp]` | `:chf` | `:gbp` (index sat on the upper bound) |
| the stored index past the end of a shorter list | the last member | the last member |

This engine follows a moved upper bound even when the stored value still
fits, never follows a moved lower bound, and fits a member by its index.

## Measured results

Both engines ran every `corpus/next` entry with seeds 1 to 20 and a plan cap
of 200. These numbers were measured on this branch before this record was
committed. `native` is `property_damage_next`; `source` is
`property_damage_next_source`.

| entry | engine | found | plans until found | mean shrink runs | reached minimum |
|---|---|---|---|---|---|
| fifth_refund | native | 20/20 | 1.8 | 31.6 | 19/20 |
| fifth_refund | source | 20/20 | 1.3 | 33.1 | 19/20 |
| long_note | native | 20/20 | 1.2 | 150.1 | 20/20 |
| long_note | source | 20/20 | 1.3 | 103.5 | 20/20 |
| lost_full_refund | native | 20/20 | 2.9 | 64.7 | 11/20 |
| lost_full_refund | source | 20/20 | 3.0 | 43.4 | 20/20 |
| nested_price | native | 20/20 | 1.3 | 22.5 | 4/20 |
| nested_price | source | 20/20 | 1.4 | 21.7 | 0/20 |
| offset_refund | native | 19/20 | 62.3 | 25.8 | 0/20 |
| offset_refund | source | 19/20 | 60.7 | 29.0 | 5/20 |
| rejected_set | native | 20/20 | 2.5 | 7.0 | 20/20 |
| rejected_set | source | 20/20 | 1.6 | 7.0 | 20/20 |

The kept list names three sites on `Engine.Native` (`fifth_refund` and
`lost_full_refund`: field `:amount`; `nested_price`: field `:price`) and none
on this engine.

The findings:

- **This engine reached the minimum more often on three entries.**
  `lost_full_refund` reached it on 20/20 seeds against 11/20, with fewer
  shrink runs (43.4 against 64.7). `offset_refund` reached it on 5/20
  against 0/20. `long_note` reached it on 20/20 on both, with fewer shrink
  runs (103.5 against 150.1).
- **This engine reached the minimum less often on `nested_price`:** 0/20
  against 4/20. It stops at a payment of 2 and a refund of 1 in the
  alternate currency. With a payment of 1, the system rejects the same
  refund (`{:error, :exceeds_balance}`), which is a different failure from
  the balance mismatch found first, so the shrinker does not adopt that
  candidate. The entry's minimum is the rejected refund. Only a seed whose
  first failure is already the rejection reaches it. Neither engine has a
  defect here.
- **A deep value, compared with StreamData's own shrinker.** One generator
  drew `list_of(fixed_map(amount: integer(1..60), currency: member_of([:base,
  :alt])))`, and the property failed on any odd `:alt` amount. The smallest
  value is `[%{amount: 1, currency: :alt}]`. Seeds 1 to 20 on each side;
  StreamData's seeds draw different first values than PD's.

  | shrinker | found | mean shrink runs | reached the smallest value |
  |---|---|---|---|
  | StreamData `check_all/3` | 20/20 | 10.6 | 1/20 |
  | this engine | 20/20 | 32.5 | 7/20 |
  | `Engine.Native` | 20/20 | 31.5 | 0/20 |

  StreamData's shrinker and `Engine.Native` stop at an amount of 3, 7 or 15:
  halving toward the lower bound jumps over the odd values between. This
  engine always reaches an amount of 1. On 13 of 20 seeds, though, it keeps
  1 to 6 extra `%{amount: 1, currency: :base}` elements. Lowering the list's
  length removes the elements nearest the head of the list, and those hold
  the failing `:alt` element, so the shrinker does not adopt that candidate.

Nothing was tuned to these numbers.

## Consequences

- `PropertyDamage.Next` has two engines. `Engine.Native` stays the default
  and needs nothing beyond the released StreamData. The second engine runs
  only where the patched StreamData is loaded, which today means the test
  environment.
- A nested StreamData value is fitted part by part on the second engine,
  and the shrinker lowers each part. A dependent StreamData site keeps no
  kept-list entry there.
- Journals saved in format version 2 cannot be loaded. Capture the failure
  again. This amends DR-069, decision 9.
- The shrinker has one more move, the source clause of decision 9. This
  amends DR-069, decision 2. The moves of `Engine.Native` entries are
  unchanged, and so are their shrink-run counts.
- The tests of the second engine carry the tag `:patched_stream_data`. With
  `PD_SKIP_STREAM_DATA_PATCH=1`, the run lists them as excluded.
- The test environment depends on the `patch` executable. Without it, the
  tagged tests are excluded locally, and the run stops on CI.
- A StreamData release that changes either private function breaks the
  patch. The apply step uses `--fuzz=0`, so it then fails instead of
  applying a shifted hunk, and the file name names the version it fits.
- A `tree/2` level size bypasses the source: the engine cannot fit it, the
  shrinker cannot lower it, and inside a list it can change on a replay.
- The second engine's fit rules differ from `Engine.Native`'s, as the table
  in "Does the patch alone suffice?" shows. This record states the
  difference; it does not change either rule.

## Alternatives considered

- **Forking StreamData, or depending on a git branch of it.** Rejected: a
  fork or a git dependency changes `mix.lock` and what every user of PD
  downloads. The patch file touches only the test environment, and the
  released dependency stays as it is.
- **Reading StreamData's private modules to reach its draws.** Rejected: a
  private function can change in any release without notice, and PD would
  depend on it at run time for every user. The patch is the only place that
  depends on private code, and an exact apply fails loudly when that code
  changes.
- **Storing a nested value as a path, as `Engine.Native` does.** Kept for
  `Engine.Native`, not chosen for this engine: a path is walked on a changed
  generator, not fitted, so a part of a nested value cannot follow the
  value it depends on.
- **Letting the shrinker read the entry's layout directly.** Rejected: the
  shrinker would then break silently when the engine changes the layout.
  The engine's `positions/1` and `put_position/3` keep the layout in one
  module.
- **Keeping journal format version 2 and adding the `:source` tag to it.**
  Rejected: a PD that loads version 2 would then accept a journal that
  holds a source entry and fail on the unknown tag during the decode or
  the replay. With version 3, that PD refuses the journal with a message
  that names both versions.
- **A failed apply that only excludes the tagged tests on CI too.**
  Rejected: the tests would then drop out of the CI count with only a line
  on stderr.
