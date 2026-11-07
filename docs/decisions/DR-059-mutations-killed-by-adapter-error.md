# DR-059: Mutations Killed by an Adapter Error

**Status:** Accepted
**Date:** 2026-11-03

## Context

Mutation testing wraps the adapter and changes what it answers. The `:status`
operator turns a success into `{:error, _}`. The run then fails with a report
of kind `:execution_failed`: a command could not be executed. The run does not
fail because a check found a wrong state.

The runner counted every failed run as a kill. A model with no checks at all
then scored above zero, because the adapter errors alone "killed" the status
mutations. The score said the checks caught a bug when no check ran.

An adapter-error kill says nothing about the checks. Any model fails that way,
however good or empty its checks are.

## Decision

1. **A new outcome, `:killed_by_error`.** A mutation whose run failed with a
   report of kind `:execution_failed` has this outcome. A run that failed with
   any other report kind is still `:killed`.

2. **The score leaves these mutations out.** `mutation_score` is
   `killed / (total - killed_by_error)`, and 0.0 when that denominator is 0.
   Timeouts stay in the denominator, as before. Each row of `by_command` and
   `by_operator` follows the same rule.

3. **The report shows both numbers.** `Report` gains `killed_by_error` and
   `killed_by_error_mutations` (the detail list, kept apart from
   `killed_mutations`). The `by_command` and `by_operator` rows gain
   `killed_by_error`. The terminal, markdown and JSON output name the count
   next to killed and survived and say the score excludes it. A progress update
   and the verbose status line carry the new outcome.

4. **A killed mutation records the report's message.** The message is
   `PropertyDamage.FailureReport.failure_message/1` of the report the run
   returned. For an error kill it names the adapter failure.

## Alternatives

- **Drop the mutations that produce errors.** The `:status` operator would
  lose its error cases. A model can still react to an adapter error through
  its checks, so the mutation stays useful. The cost is a smaller operator.
- **Document only: count them as kills and explain.** The number stays
  wrong for the reader who skips the note. A score that rises when checks are
  removed is a defect in the number, not in the reading.
- **Count them in the score.** This is the old behavior. It rewards a model
  for failing, not for checking.

## Consequences

- Scores drop for models whose kills came partly from adapter errors. A model
  with no checks now scores 0.0.
- A score of 0.0 can mean "no mutation was measurable". The report shows
  `killed_by_error` so the reader can tell that case from a model whose
  checks caught nothing.
- A code path that matches the outcome of a mutation must handle a fourth
  value. The report struct only gains fields, so no persisted data changes.
