defmodule PropertyDamage.TargetsOptionTest do
  use ExUnit.Case, async: true

  alias PropertyDamage.Options
  alias PropertyDamage.Test.{ExecutorModel, SimpleAdapter, TestAdapter}

  @model ExecutorModel

  # The run schema and a single-target schema share the per-entry and
  # cross-entry target rules, so most tests run once per schema. Each schema
  # gets a minimal otherwise-valid option list.
  @schemas [:run, :execute]

  defp validate(:run, targets), do: Options.validate_run!(model: @model, targets: targets)

  defp validate(:execute, targets), do: Options.validate_execute!(targets: targets)

  defp assert_targets_error(fun, text) do
    error = assert_raise NimbleOptions.ValidationError, fun
    assert error.key == :targets
    assert Exception.message(error) =~ text
    error
  end

  describe "required and empty targets" do
    for schema <- @schemas do
      test "#{schema}: omitting targets raises with key :targets" do
        fun =
          case unquote(schema) do
            :run -> fn -> Options.validate_run!(model: @model) end
            :execute -> fn -> Options.validate_execute!([]) end
          end

        error = assert_raise NimbleOptions.ValidationError, fun
        assert error.key == :targets
      end

      test "#{schema}: an empty targets list raises with key :targets" do
        error =
          assert_raise NimbleOptions.ValidationError, fn -> validate(unquote(schema), []) end

        assert error.key == :targets
      end
    end
  end

  describe "entry forms" do
    for schema <- @schemas do
      test "#{schema}: rejects malformed entries" do
        for bad <- [{SimpleAdapter}, "SimpleAdapter", {SimpleAdapter, %{name: "x"}}, nil] do
          error =
            assert_raise NimbleOptions.ValidationError, fn ->
              validate(unquote(schema), [bad])
            end

          assert error.key == :targets, "expected key :targets for #{inspect(bad)}"
        end
      end

      test "#{schema}: rejects a validated target struct as an entry" do
        target = struct(PropertyDamage.Target, adapter: SimpleAdapter, name: "x", index: 0)

        assert_targets_error(
          fn -> validate(unquote(schema), [target]) end,
          "targets entry 0 is malformed"
        )
      end

      test "#{schema}: accepts a bare module and a module with a keyword" do
        for entry <- [SimpleAdapter, {SimpleAdapter, name: "named"}] do
          assert [t] = validate(unquote(schema), [entry])[:targets]
          assert t.adapter == SimpleAdapter
        end
      end

      test "#{schema}: rejects unknown per-target keys, naming the key" do
        for key <- [:foo, :expansion, :settle] do
          assert_targets_error(
            fn -> validate(unquote(schema), [{SimpleAdapter, [{key, 1}]}]) end,
            Atom.to_string(key)
          )
        end
      end
    end
  end

  describe "normalization" do
    for schema <- @schemas do
      test "#{schema}: returns a targets struct with the pinned fields" do
        assert [t] = validate(unquote(schema), [{SimpleAdapter, name: "b"}])[:targets]
        assert t.__struct__ == PropertyDamage.Target

        assert t |> Map.from_struct() |> Map.keys() |> Enum.sort() ==
                 [:adapter, :config, :index, :injectors, :mocks, :name]

        assert t.index == 0
        assert t.name == "b"
      end

      test "#{schema}: a bare module and an empty keyword get the same defaults" do
        for entry <- [SimpleAdapter, {SimpleAdapter, []}] do
          assert [t] = validate(unquote(schema), [entry])[:targets]
          assert t.adapter == SimpleAdapter
          assert t.name == "SimpleAdapter"
          assert t.config == %{}
          assert t.injectors == []
          assert t.mocks == []
          assert t.index == 0
        end
      end
    end

    test "run keeps targets in input order with 0-based indexes" do
      opts = validate(:run, [SimpleAdapter, {TestAdapter, name: "b"}])

      assert [t0, t1] = opts[:targets]
      assert t0.__struct__ == PropertyDamage.Target
      assert t1.__struct__ == PropertyDamage.Target
      assert {t0.index, t0.adapter, t0.name} == {0, SimpleAdapter, "SimpleAdapter"}
      assert {t1.index, t1.adapter, t1.name} == {1, TestAdapter, "b"}
    end

    test "the removed multi-target modules are gone" do
      # Built at runtime: the removed names appear nowhere in source.
      refute Code.ensure_loaded?(Module.concat([PropertyDamage, "Differential", "Target"]))
      refute Code.ensure_loaded?(Module.concat([PropertyDamage, "Differential"]))
    end
  end

  describe "types" do
    for schema <- @schemas do
      test "#{schema}: config reaches the struct unchanged" do
        config = %{"tenant" => "t1", :k => [1]}
        assert [t | _] = validate(unquote(schema), [{SimpleAdapter, config: config}])[:targets]
        assert t.config === config
      end

      test "#{schema}: a keyword config raises and names config" do
        assert_targets_error(
          fn -> validate(unquote(schema), [{SimpleAdapter, config: [a: 1]}]) end,
          "config"
        )
      end

      test "#{schema}: injectors are a list of modules kept as given" do
        assert [t | _] =
                 validate(unquote(schema), [{SimpleAdapter, injectors: [TestAdapter]}])[:targets]

        assert t.injectors == [TestAdapter]
      end

      test "#{schema}: non-list or non-module injectors raise" do
        for bad <- [TestAdapter, ["x"]] do
          error =
            assert_raise NimbleOptions.ValidationError, fn ->
              validate(unquote(schema), [{SimpleAdapter, injectors: bad}])
            end

          assert error.key == :targets, "expected key :targets for injectors: #{inspect(bad)}"
        end
      end

      test "#{schema}: mocks normalize to {module, map} pairs" do
        entry = {SimpleAdapter, mocks: [TestAdapter, {ExecutorModel, %{a: 1}}]}
        assert [t | _] = validate(unquote(schema), [entry])[:targets]
        assert t.mocks == [{TestAdapter, %{}}, {ExecutorModel, %{a: 1}}]
      end

      test "#{schema}: a keyword mock config raises" do
        assert_targets_error(
          fn ->
            validate(unquote(schema), [{SimpleAdapter, mocks: [{TestAdapter, [a: 1]}]}])
          end,
          ""
        )
      end
    end
  end

  describe "cross-entry rules" do
    for schema <- @schemas do
      test "#{schema}: two bare entries for one adapter collide on the default name" do
        assert_targets_error(
          fn -> validate(unquote(schema), [SimpleAdapter, SimpleAdapter]) end,
          ~s(name: "SimpleAdapter")
        )
      end

      test "#{schema}: two entries with the same explicit name collide" do
        assert_targets_error(
          fn ->
            validate(unquote(schema), [
              {SimpleAdapter, name: "x"},
              {TestAdapter, name: "x"}
            ])
          end,
          ~s(name: "x")
        )
      end
    end

    test "the same adapter twice is valid in run when names differ" do
      assert [a, b] =
               validate(:run, [SimpleAdapter, {SimpleAdapter, name: "second"}])[:targets]

      assert {a.name, b.name} == {"SimpleAdapter", "second"}
    end

    test "two entries resolving to one name are a duplicate-name error in the run schema" do
      error =
        assert_raise NimbleOptions.ValidationError, fn ->
          Options.validate_run!(model: @model, targets: [SimpleAdapter, SimpleAdapter])
        end

      assert error.key == :targets
      assert Exception.message(error) =~ ~s(name: "SimpleAdapter")
      refute Exception.message(error) =~ "exactly one"
    end
  end

  describe "target count" do
    test "run accepts several targets" do
      assert [_, _] =
               Options.validate_run!(
                 model: @model,
                 targets: [SimpleAdapter, {SimpleAdapter, name: "b"}]
               )[:targets]
    end

    test "a single-target entry point requires exactly one target and names run/1" do
      error =
        assert_targets_error(
          fn -> validate(:execute, [SimpleAdapter, {SimpleAdapter, name: "b"}]) end,
          "exactly one"
        )

      assert Exception.message(error) =~ "PropertyDamage.run/1"
      refute Exception.message(error) =~ "Differential"
    end

    test "run accepts a single target" do
      assert [t] = validate(:run, [SimpleAdapter])[:targets]
      assert t.index == 0
    end
  end

  describe "retired run-level keys" do
    @retired [
      {:adapter, SimpleAdapter,
       "`adapter:` was replaced by `targets:`; pass the adapter module as a `targets:` entry"},
      {:adapter_config, %{a: 1},
       "`adapter_config:` was replaced by `targets:`; pass the map as `config:` in a `targets:` entry"},
      {:injector_adapters, [TestAdapter],
       "`injector_adapters:` was replaced by `targets:`; pass the modules as `injectors:` in a `targets:` entry"},
      {:mock_services, [TestAdapter],
       "`mock_services:` was replaced by `targets:`; pass the entries as `mocks:` in a `targets:` entry"}
    ]

    for {key, value, text} <- @retired do
      test "run schema rejects #{key}:" do
        error =
          assert_raise NimbleOptions.ValidationError, fn ->
            Options.validate_run!([
              {unquote(key), unquote(Macro.escape(value))},
              model: @model,
              targets: [SimpleAdapter]
            ])
          end

        assert error.key == unquote(key)
        assert Exception.message(error) =~ unquote(text)
      end

      test "run schema with two targets rejects #{key}:" do
        error =
          assert_raise NimbleOptions.ValidationError, fn ->
            Options.validate_run!([
              {unquote(key), unquote(Macro.escape(value))},
              model: @model,
              targets: [SimpleAdapter, {TestAdapter, name: "other"}]
            ])
          end

        assert error.key == unquote(key)
        assert Exception.message(error) =~ unquote(text)
      end
    end

    test "PropertyDamage.run/1 without targets reports the retired adapter key" do
      error =
        assert_raise NimbleOptions.ValidationError, fn ->
          PropertyDamage.run(model: @model, adapter: SimpleAdapter)
        end

      assert error.key == :adapter

      assert Exception.message(error) =~
               "`adapter:` was replaced by `targets:`; pass the adapter module as a `targets:` entry"

      refute Exception.message(error) =~ "required :targets option not found"
    end
  end

  describe "retired per-target keys" do
    for schema <- @schemas do
      test "#{schema}: role is removed" do
        assert_targets_error(
          fn -> validate(unquote(schema), [{SimpleAdapter, role: :reference}]) end,
          "`role:` was removed; the first `targets:` entry is the reference"
        )
      end

      test "#{schema}: opts is renamed config" do
        assert_targets_error(
          fn -> validate(unquote(schema), [{SimpleAdapter, opts: %{a: 1}}]) end,
          "`opts:` was renamed `config:`"
        )
      end
    end
  end
end
