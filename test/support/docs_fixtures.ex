defmodule PropertyDamage.Test.DocsFixtures.Model do
  @moduledoc """
  Model fixture for doc capture.
  """
  use PropertyDamage.Model

  @impl true
  # line:model.commands
  def commands, do: [PropertyDamage.Test.DocsFixtures.Command]

  @doc "Names the projection."
  @impl true
  # line:model.command_sequence_projection
  def command_sequence_projection, do: PropertyDamage.Test.DocsFixtures.Projection

  @doc false
  # line:model.hidden_note
  def hidden_note, do: :hidden

  # line:model.undocumented_note
  def undocumented_note, do: quiet_helper()

  @doc "Classifies by sign."
  # line:model.classify
  def classify(n) when n > 0, do: :positive
  def classify(_), do: :other

  @doc "Head doc."
  # line:model.headed
  def headed(value)
  def headed(value), do: value

  defmacro a_macro(value), do: value

  def __helper__, do: :helper

  defp quiet_helper, do: :quiet
end

defmodule PropertyDamage.Test.DocsFixtures.Projection do
  @moduledoc false
  use PropertyDamage.Model.Projection

  @impl true
  # line:projection.init
  def init, do: %{total: 0}

  @doc "Adds the amount of an event to the total."
  @impl true
  # line:projection.apply
  def apply(state, %{amount: amount}), do: %{state | total: state.total + amount}
  def apply(state, _event), do: state

  @check every: 1
  @doc "Total never goes negative."
  # line:projection.assert_total_not_negative
  def assert_total_not_negative(state, _event), do: state.total >= 0

  @doc false
  # line:projection.hidden_total
  def hidden_total(state), do: state.total

  # line:projection.plain_total
  def plain_total(state), do: state.total
end

# A missing moduledoc is the case under test.
# credo:disable-for-next-line Credo.Check.Readability.ModuleDoc
defmodule PropertyDamage.Test.DocsFixtures.Command do
  use PropertyDamage.Command

  @impl true
  @doc "Generates an empty command."
  # line:command.generator
  def generator(_overrides), do: StreamData.fixed_map([])

  @doc false
  # line:command.internal_note
  def internal_note, do: :internal

  # line:command.plain_note
  def plain_note, do: :plain
end

defmodule PropertyDamage.Test.DocsFixtures.PlainHidden do
  @moduledoc false

  @doc "Documented in a hidden module."
  def shown, do: :shown

  @doc false
  def hidden, do: :hidden
end

# A missing moduledoc is the case under test.
# credo:disable-for-next-line Credo.Check.Readability.ModuleDoc
defmodule PropertyDamage.Test.DocsFixtures.PlainBare do
  def undocumented, do: :undocumented
end

defmodule PropertyDamage.Test.DocsFixtures.Sentinel do
  @moduledoc """
  Moduledoc sentinel: MODULEDOC_SENTINEL_5f0c1d.
  """
  use PropertyDamage.Command

  # Comment sentinel: COMMENT_SENTINEL_9b7e2a. It sits in a code comment only.
  @impl true
  def generator(_overrides), do: StreamData.fixed_map([])
end
