defmodule PropertyDamage.FailureReport.BundleRobustnessTest do
  # Odd shapes of a source file must neither stop the page from being
  # written nor leak a secret.
  use ExUnit.Case, async: false

  alias PropertyDamage.Test.BundleSupport, as: B
  alias PropertyDamage.Test.Compare

  setup do
    previous = System.get_env("PD_LOG")
    System.delete_env("PD_LOG")

    on_exit(fn ->
      if previous, do: System.put_env("PD_LOG", previous), else: System.delete_env("PD_LOG")
    end)

    :ok
  end

  # Every function of a readable file has a range on lines of the file whose
  # first line holds a definition, or a null id.
  defp assert_checkable(entry, text) do
    lines = String.split(text, "\n")
    assert entry["lines"] >= 1

    for function <- entry["functions"], function["id"] != nil do
      from = function["from"]
      to = function["to"]
      assert is_integer(from) and is_integer(to), "id without a range: #{inspect(function)}"
      assert from in 1..entry["lines"]
      assert to in from..entry["lines"]
      assert Enum.at(lines, from - 1) =~ ~r/\bdefp?\b/
    end
  end

  test "a model written on one line gives a bundle and a page with one bundle tag" do
    p = "PropertyDamage.Test.OneLine#{B.suffix()}"

    source =
      "defmodule #{p}.OneLine, do: (use PropertyDamage.Model; def commands, do: []; " <>
        "def command_sequence_projection, do: PropertyDamage.Test.Compare.Counter)\n"

    compiled = B.compile_file(source, "one_line_model.ex")
    model = Module.concat([p, "OneLine"])
    report = B.hand_report(model, [{Compare.PayAdapter, "alice"}])

    bundle = B.build(report)
    assert B.bundle_id_count(B.render(report)) == 1

    entry = B.module_entry(bundle, model)
    assert File.read!(compiled.file) == source
    assert entry["functions"] != []
    assert_checkable(entry, source)
  end

  test "a bare adapter written on one line gives a bundle" do
    p = "PropertyDamage.Test.OneLineAdapter#{B.suffix()}"

    source =
      "defmodule #{p}.OneLine, do: (@behaviour PropertyDamage.Adapter; " <>
        "def setup(c), do: {:ok, c}; def teardown(_c), do: :ok; " <>
        "def execute(_a, _b, _c), do: {:ok, []}; def timeout(_c), do: 1)\n"

    B.compile_file(source, "one_line_adapter.ex")
    adapter = Module.concat([p, "OneLine"])
    report = B.hand_report(Compare.PlainModel, [{adapter, "alice"}])

    bundle = B.build(report)
    assert B.bundle_id_count(B.render(report)) == 1
    assert_checkable(B.module_entry(bundle, adapter), source)
  end

  test "redacts a module that is both the model and the adapter" do
    system = B.define()
    p = system.prefix

    source = """
    defmodule #{p}.Both do
      use PropertyDamage.Model
      use PropertyDamage.Adapter
      @admin_password "hunter2"

      def admin_password, do: @admin_password

      @impl PropertyDamage.Model
      def commands, do: [{#{p}.Pay, overrides: &number/1}]

      @impl PropertyDamage.Model
      def command_sequence_projection, do: #{p}.Counter

      @impl PropertyDamage.Model
      def check_projections, do: [#{p}.Ledger]

      @impl PropertyDamage.Adapter
      def setup(config), do: {:ok, config}

      @impl PropertyDamage.Adapter
      def teardown(_ctx), do: :ok

      @impl PropertyDamage.Adapter
      def execute(%#{p}.Pay{n: n, amount: amount}, ctx, _runtime) do
        {:ok, [%#{p}.Paid{n: n, amount: -amount, by: ctx.name}]}
      end

      defp number(state), do: %{n: state.count}
    end
    """

    compiled = B.compile_file(source, "both.ex")
    both = Module.concat([p, "Both"])

    # positive control: the literal is in the file
    assert File.read!(compiled.file) =~ "hunter2"

    bundle =
      %{system | model: both}
      |> B.run([{both, [name: "alice", config: %{name: "alice"}]}])
      |> B.build()

    entry = B.module_entry(bundle, both)

    assert entry["source"] =~ "[REDACTED]"
    refute entry["source"] =~ "hunter2"
    assert entry["redactions"] >= 1

    per_module = bundle["modules"] |> Enum.map(& &1["redactions"]) |> Enum.sum()
    assert bundle["redactions"]["count"] == per_module
  end
end
