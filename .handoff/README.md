# Handoff ledgers

One file per branch, named after the branch with `/` replaced by `-`. A ledger
records what a branch was asked to do, the sessions that worked on it, the
decisions taken on the way and what was verified, so a reviewer asked to take
ownership of the pull request gets the context the author had. The ledger is
deleted on the branch before the pull request merges; the published handoff
package on the pull request is its permanent home.
