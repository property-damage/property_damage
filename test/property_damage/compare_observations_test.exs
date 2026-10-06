defmodule PropertyDamage.CompareObservationsTest do
  # A model module is loaded on its first remote call, and an optional
  # callback looked up with `function_exported?/3` before that call reads as
  # absent. The observations a model declares must not depend on whether
  # something else loaded the model first.
  use ExUnit.Case, async: true

  alias PropertyDamage.Comparison

  defmodule Observed do
    @moduledoc false
    use PropertyDamage.Model.Projection

    @impl true
    def init, do: %{count: 0}

    @impl true
    def apply(state, _event), do: state

    @compare every: 1
    def count(state, _root), do: state.count
  end

  @model PropertyDamage.CompareObservationsTest.UnloadedModel

  @source """
  defmodule #{inspect(@model)} do
    @behaviour PropertyDamage.Model

    @impl true
    def commands, do: PropertyDamage.Test.Compare.commands(:pay)

    @impl true
    def command_sequence_projection, do: PropertyDamage.Test.Compare.Counter

    @impl true
    def check_projections, do: [#{inspect(Observed)}]
  end
  """

  # Compiles the model to a .beam file on the code path, then unloads it, so
  # the next call into it is its first.
  defp unloaded_model!(dir) do
    [{module, binary}] = Code.compile_string(@source, "unloaded_model.exs")
    File.write!(Path.join(dir, "#{module}.beam"), binary)
    Code.prepend_path(dir)
    :code.purge(module)
    :code.delete(module)
    module
  end

  @tag :tmp_dir
  test "reads the observations of check projections on a model not loaded yet", %{tmp_dir: dir} do
    model = unloaded_model!(dir)
    on_exit(fn -> Code.delete_path(dir) end)

    refute Code.loaded?(model)

    assert [%{key: {Observed, :count}}] = Comparison.observations(model)
  end
end
