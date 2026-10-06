defmodule PropertyDamage.Target do
  @moduledoc """
  One system variant a run executes against: an adapter module plus the
  configuration, injectors and mocks that go with it.

  Every entry point that runs commands takes a `targets:` list. Each entry is
  either a bare adapter module or a tuple of the module and a keyword list:

      targets: [MyApp.Adapter]

      targets: [
        {MyApp.Adapter,
         name: "staging",
         config: %{base_url: "https://staging.example.com", tenant: "t-1"},
         injectors: [MyApp.WebhookInjector],
         mocks: [{MyApp.PaymentMock, %{latency_ms: 5}}]}
      ]

  Entry keys:

    * `:name` (string): label used in reports and divergences. Defaults to the
      last segment of the adapter module name. Names must be unique within one
      list.
    * `:config` (map, default `%{}`): passed to `c:PropertyDamage.Adapter.setup/1`
      unchanged. When two targets run against one system, give each its own
      `config:` (for example a tenant) so their variants isolate their slices of
      state.
    * `:injectors` (list of modules, default `[]`): injector adapters that push
      events into the run.
    * `:mocks` (list, default `[]`): mock services the system under test calls;
      each entry is a `PropertyDamage.MockServiceAdapter` module or a
      `{module, config_map}` tuple.
    * `:expansion` (`:random`, `:identity` or `:reference`, default `:random`):
      how this target chooses at each root the model's `expansions/0` lists.
      `:random` draws an expansion by weight from the run's seed, this
      target's name and the root's index; `:identity` runs every root as
      itself; `:reference` runs exactly what the first target ran, leaf for
      leaf. The first target is the reference, so it cannot be `:reference`.
      For a model without `expansions/0` every value runs the roots.

  The first entry is the reference: `PropertyDamage.run/1` compares every
  other target against it. Every other entry point takes exactly one entry.

  Validation turns each entry into a `%PropertyDamage.Target{}` whose `:index`
  is the entry's zero-based position in the list.
  """

  @type mock :: {module(), map()}

  @type t :: %__MODULE__{
          adapter: module(),
          name: String.t(),
          index: non_neg_integer(),
          config: map(),
          injectors: [module()],
          mocks: [mock()],
          expansion: :random | :identity | :reference
        }

  defstruct [:adapter, :name, :index, config: %{}, injectors: [], mocks: [], expansion: :random]

  @doc false
  # The name a target gets when its entry sets none: the last segment of the
  # adapter module name.
  @spec default_name(module() | nil) :: String.t() | nil
  def default_name(nil), do: nil
  def default_name(adapter) when is_atom(adapter), do: adapter |> Module.split() |> List.last()

  @doc false
  # Rebuilds the `targets:` entry that validates back into `target`, for
  # internal callers that re-enter a validating entry point with a target they
  # already hold.
  @spec to_entry(t()) :: {module(), keyword()}
  def to_entry(%__MODULE__{} = target) do
    {target.adapter,
     name: target.name,
     config: target.config,
     injectors: target.injectors,
     mocks: target.mocks,
     expansion: target.expansion}
  end
end
