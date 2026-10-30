defmodule PropertyDamage.FailureReport.BundleSharedFileTest do
  # A source file that holds an adapter shows its text through every module
  # defined in it, so the redaction covers each of those modules, not only
  # the adapter.
  use ExUnit.Case, async: false

  alias PropertyDamage.Test.BundleSupport, as: B

  setup do
    previous = System.get_env("PD_LOG")
    System.delete_env("PD_LOG")

    on_exit(fn ->
      if previous, do: System.put_env("PD_LOG", previous), else: System.delete_env("PD_LOG")
    end)

    :ok
  end

  # A model above an adapter in one file. The model carries the secret
  # literal; the commands and projections come from `B.define/1`.
  defp shared_source(p) do
    """
    defmodule #{p}.SharedModel do
      @moduledoc "A model that shares its file with an adapter."
      use PropertyDamage.Model

      @impl true
      def commands, do: [{#{p}.Pay, overrides: &number/1}]

      @impl true
      def command_sequence_projection, do: #{p}.Counter

      @impl true
      def check_projections, do: [#{p}.Ledger]

      @login [user: "alice", password: "hunter2"]
      def login, do: @login

      defp number(state), do: %{n: state.count}
    end

    defmodule #{p}.SharedAdapter do
      @moduledoc "An adapter in the file of a model."
      use PropertyDamage.Adapter

      @impl true
      def setup(config), do: {:ok, config}

      @impl true
      def teardown(_ctx), do: :ok

      @impl true
      def execute(%#{p}.Pay{n: n, amount: amount}, ctx, _runtime) do
        {:ok, [%#{p}.Paid{n: n, amount: -amount, by: ctx.name}]}
      end
    end
    """
  end

  test "redacts the source of a non-adapter module that shares a file with an adapter" do
    system = B.define()
    p = system.prefix
    shared = B.compile_file(shared_source(p), "shared.ex")
    model = Module.concat([p, "SharedModel"])
    adapter = Module.concat([p, "SharedAdapter"])

    # positive control: the literal is in the file the two modules share
    assert File.read!(shared.file) =~ "hunter2"

    target = {adapter, [name: "alice", config: %{name: "alice"}]}
    bundle = %{system | model: model} |> B.run([target]) |> B.build()

    model_entry = B.module_entry(bundle, model)
    adapter_entry = B.module_entry(bundle, adapter)

    assert model_entry["file"] == adapter_entry["file"]

    for entry <- [model_entry, adapter_entry] do
      assert entry["source"] =~ "[REDACTED]"
      refute entry["source"] =~ "hunter2"
      assert entry["redactions"] >= 1
    end

    per_module = bundle["modules"] |> Enum.map(& &1["redactions"]) |> Enum.sum()
    assert bundle["redactions"]["count"] == per_module
    assert bundle["redactions"]["count"] >= 2
  end
end
