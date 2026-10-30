---
name: pd-explain
description: Explain a PropertyDamage failure page. Use when asked to "explain this failure page" or to run `mix pd.explain` on an HTML failure page.
---

# Explain a failure page

PAGE is the path of the HTML failure page. Run every command from the Mix project that wrote the page.

1. Run `mix pd.explain PAGE`. If it prints that the page is already explained (`PAGE is already explained (bundle ..., prompt version ...)`), stop and report the page path.
2. Read `PAGE.explain/instructions.md`.
3. Read `PAGE.explain/bundle.json`.
4. Write `explanation.json` next to the page, as the instructions describe.
5. Run `mix pd.explain PAGE --apply explanation.json`.
6. If it exits non-zero, read the error lines, fix `explanation.json`, and apply again, up to 3 attempts in all.
7. Report the page path and a short summary of the explanation.
