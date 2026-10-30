defmodule PropertyDamage.FailureReport.BundleSubAdapterTest do
  # An adapter that hands commands to another module through
  # `delegate_execution/1` runs code that module holds, so the bundle lists
  # it, and redacts its file like any adapter file.
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

  defp main_source(p) do
    """
    defmodule #{p}.Main do
      use PropertyDamage.Adapter

      delegate_execution for: [#{p}.Pay], to: #{p}.Sub

      @impl true
      def setup(config), do: {:ok, config}

      @impl true
      def teardown(_ctx), do: :ok
    end
    """
  end

  defp sub_source(p) do
    """
    defmodule #{p}.Sub do
      use PropertyDamage.Adapter

      @admin_password "hunter2"

      delegate_execution for: [#{p}.Pay], to: #{p}.SubSub

      def admin_password, do: @admin_password
    end
    """
  end

  defp sub_sub_source(p) do
    """
    defmodule #{p}.SubSub do
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

  test "lists the sub-adapters after the delegating adapter and redacts their files" do
    system = B.define()
    p = system.prefix
    main_file = B.compile_file(main_source(p), "main.ex")
    sub_file = B.compile_file(sub_source(p), "sub.ex")
    B.compile_file(sub_sub_source(p), "sub_sub.ex")
    main = Module.concat([p, "Main"])
    sub = Module.concat([p, "Sub"])
    sub_sub = Module.concat([p, "SubSub"])

    # positive control: the literal is in the file of the sub-adapter
    assert File.read!(sub_file.file) =~ "hunter2"
    refute File.read!(main_file.file) =~ "hunter2"

    target = {main, [name: "alice", config: %{name: "alice"}]}
    bundle = system |> B.run([target]) |> B.build()

    modules = bundle["modules"]
    names = Enum.map(modules, & &1["module"])
    index = fn module -> Enum.find_index(names, &(&1 == inspect(module))) end

    for module <- [main, sub, sub_sub] do
      assert Enum.count(names, &(&1 == inspect(module))) == 1
      assert B.module_entry(bundle, module)["role"] == "adapter"
    end

    assert index.(sub) == index.(main) + 1
    assert index.(sub_sub) == index.(sub) + 1

    entry = B.module_entry(bundle, sub)
    assert entry["source"] =~ "[REDACTED]"
    refute entry["source"] =~ "hunter2"
    assert entry["redactions"] >= 1

    per_module = modules |> Enum.map(& &1["redactions"]) |> Enum.sum()
    assert bundle["redactions"]["count"] == per_module
  end

  test "a bare behaviour adapter has no sub-adapter and does not raise" do
    p = "PropertyDamage.Test.BareSub#{B.suffix()}"

    source =
      "defmodule #{p}.Bare, do: (@behaviour PropertyDamage.Adapter; " <>
        "def setup(c), do: {:ok, c}; def teardown(_c), do: :ok; " <>
        "def execute(_a, _b, _c), do: {:ok, []}; def timeout(_c), do: 1)\n"

    B.compile_file(source, "bare.ex")
    bare = Module.concat([p, "Bare"])
    report = B.hand_report(Compare.PlainModel, [{bare, "alice"}])

    bundle = B.build(report)
    adapters = for %{"role" => "adapter", "module" => name} <- bundle["modules"], do: name
    assert adapters == [inspect(bare)]
  end
end
