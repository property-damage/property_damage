---
name: pd-explain
description: Explain a PropertyDamage failure page. Use when asked to "explain this failure page" or to run `mix pd.explain` on an HTML failure page.
---

# Explain a failure page

PAGE is the path of the HTML failure page. Run every command from the Mix project that wrote the page. Use the same PAGE text in every command.

1. Run `mix pd.explain PAGE --files`. Always pass `--files`: it writes the files and never runs a command, even when the project sets `explain_with`. If it prints that the page is already explained (`PAGE is already explained (bundle ..., prompt version ...)`), stop and report the page path.
2. Read `PAGE.explain/instructions.md`.
3. Read `PAGE.explain/bundle.json`.
4. Write your answer to `PAGE.explain/explanation.json`, as the instructions describe.
5. Run `mix pd.explain PAGE --apply PAGE.explain/explanation.json`. If it exits 0, go to step 7.
6. If it exits non-zero, read the error lines on standard error.
   - Retry only if every error line is one of these:
     - starts with `schema:`
     - starts with `bundle hash mismatch:`
     - ends with `: a missing description is not evidence`
     - ends with `: not in this page`
     - contains `: lines ` and ends with a range such as `outside 1-40`

     Fix `PAGE.explain/explanation.json` and run step 5 again, up to 3 attempts in all. After the third failure, stop and report the error lines and the page path.
   - If the only error line says that `PAGE.explain/explanation.json` (or whatever path you passed to `--apply`) does not exist, you did not write the file at that path. Write it at the path the line names, then run step 5 again. This counts as an attempt.
   - On any other error, stop at once without retrying, and report the error lines and the page path. Editing `explanation.json` cannot fix them. Examples are `PAGE does not exist` (the page itself is missing), a usage line, `cannot read`, a symbolic link or read-only page, and `an earlier explanation in this page is malformed`. For the last one, the page needs its `pd-explanation` script tag removed by hand.
7. Report the page path and a short summary of the explanation.
