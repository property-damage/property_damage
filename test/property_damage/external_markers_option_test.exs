defmodule PropertyDamage.ExternalMarkersOptionTest do
  @moduledoc """
  DR-032: `external_markers` is an explicit run option, not ambient app config.

  `External` no longer consults `Application.get_env(:property_damage,
  :external_markers, ...)`. The explicit markers list is the sole source for
  recognizing atom markers; only the `%External{}` struct and protocol
  implementers are recognized intrinsically (without a markers list).
  """
  # async: false because it sets/clears the legacy Application env that the
  # pre-DR-032 implementation used to read.
  use ExUnit.Case, async: false

  alias PropertyDamage.External

  setup do
    Application.put_env(:property_damage, :external_markers, [:__legacy_config__])
    on_exit(fn -> Application.delete_env(:property_damage, :external_markers) end)
    :ok
  end

  test "external?/1 does not consult app config for atom markers" do
    refute External.external?(:__legacy_config__),
           "app-config markers must no longer be an ambient channel"

    # The intrinsic forms still hold without a markers list.
    assert External.external?(%External{})
  end

  test "external?/2 does not combine the explicit list with app config" do
    refute External.external?(:__legacy_config__, []),
           "app-config markers must not be merged into the explicit list"

    # The explicit list is the sole source for atom markers.
    assert External.external?(:__x__, [:__x__])
    assert External.external?(%External{}, [])
  end

  test "external_paths uses only the explicit markers list" do
    # ExternalPathsFixture marks :id with the :__x__ atom marker. App config
    # carries a different atom, so app config alone must find nothing.
    assert External.external_paths(ExternalPathsFixture, [:__x__]) == [[:id]]
    assert External.external_paths(ExternalPathsFixture, []) == []
    # external_paths/1 (no list) likewise must not pick up app config markers.
    assert External.external_paths(ExternalPathsFixture) == []
  end
end

defmodule ExternalPathsFixture do
  @moduledoc false
  defstruct [:amount, id: :__x__]
end
