defmodule PropertyDamage.Mix.TaskSupportTest do
  use ExUnit.Case, async: true

  alias PropertyDamage.Mix.TaskSupport

  # `load_project_modules/0` is the shared helper `mix pd.replay` / `mix
  # pd.reshrink` call after compiling, so a saved failure's struct atoms exist
  # before the (`:safe`) term decode. Running inside the PropertyDamage project
  # itself, it loads PropertyDamage's own modules.
  describe "load_project_modules/0" do
    test "returns :ok and leaves the current project's modules loaded" do
      assert TaskSupport.load_project_modules() == :ok
      assert Code.ensure_loaded?(PropertyDamage.Persistence)
      assert Code.ensure_loaded?(PropertyDamage.Sequence.Position)
    end
  end
end
