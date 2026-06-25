defmodule GiteaBench do
  @moduledoc """
  PropertyDamage against [Gitea](https://about.gitea.com): the dual-transport rung
  of the bench ladder.

  One transport-agnostic `GiteaBench.Model` defines a chain of intents
  (CreateUser → CreateRepo → CreateIssue → CreateLabel → AddLabelToIssue →
  CloseIssue). Two adapters realize that same intent two ways:

    * `GiteaBench.ApiAdapter` drives Gitea's REST API.
    * `GiteaBench.UiAdapter` drives the web UI with Playwright.

  Run the suite against each transport on its own (the model's invariants hold
  either way), then run `PropertyDamage.Differential.run/1` with both adapters as
  targets to assert the two transports agree, using the API as the reference
  oracle. See `test/gitea_bench_test.exs`.
  """

  @doc "Canonical `owner/name` reference for a repo."
  def full_name(owner, name), do: owner <> "/" <> name

  @doc "Split an `owner/name` reference back into `{owner, name}`."
  def split_full_name(full_name) do
    [owner, name] = String.split(full_name, "/", parts: 2)
    {owner, name}
  end
end
