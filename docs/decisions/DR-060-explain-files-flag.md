# DR-060: A Flag That Asks `mix pd.explain` for the Files

**Status:** Accepted
**Date:** 2026-11-03

## Context

DR-058 lets a project set `config :property_damage, explain_with: CMD`. With
that config, `mix pd.explain PAGE` runs `CMD` instead of writing the files
`PAGE.explain/bundle.json` and `PAGE.explain/instructions.md`.

A caller that writes the explanation itself, such as an agent skill, needs the
files. In a project that sets the config, it gets a command run instead, and
the command may cost money. The caller has no way to ask for the files.

## Decision

`mix pd.explain PAGE --files` runs the file mode that the task has without an
option, and never runs a command, whatever `explain_with` says.

1. It writes the same two files, prints the same lines and prints the same
   "already explained" line, which writes nothing.
2. It prints no config notice, because the config does not apply.
3. Without any flag, the config applies as before.
4. `--files` cannot be combined with `--prompt`, `--apply` or `--with`. That is
   a usage error naming the pair.
5. `--attempts` and `--timeout` still need `--with`, and `--files` takes no
   value.

## Alternatives

- **File mode ignores the config always.** Rejected: a project that set the
  config asked for `mix pd.explain PAGE` to run its command, and DR-058 gives
  it that.
- **An environment variable that turns the config off.** Rejected: the choice
  belongs to one call, and a variable is hidden state that a later command in
  the same shell inherits.
- **The caller unsets the config.** Rejected: the caller would have to edit the
  project config or run Mix with a different config for one call, and the
  config can sit in a file the caller does not own.

## Consequences

- A skill can pass `--files` and get the files in every project.
- The task gains one flag and three usage errors.
- A user who types `mix pd.explain PAGE` in a project with the config sees no
  change.
