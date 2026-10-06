defmodule PropertyDamage.ExpansionValidateLeavesTest do
  # `mix pd.validate --seeds` treats a leaf module the sample reached as a
  # command a run executes: a reached leaf that declares no `:observables`
  # gets the same warning as a root that declares none.
  #
  # Not async: `mix pd.validate` runs the compile task and prints to stdout.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Pd.Validate
  alias PropertyDamage.Test.ExpansionRun, as: X
  alias PropertyDamage.Test.ExpansionRun.{Capture, Pay, RecordingAdapter}

  test "warns for a reached leaf that declares no observables" do
    model =
      X.define_model!(ExpansionValidateLeaves.Model,
        commands: [Pay],
        expansions: [{Pay, &X.pay_rewrite/2}]
      )

    args = [inspect(model), inspect(RecordingAdapter), "--seed", "1", "--seeds", "5"]
    output = capture_io(fn -> send(self(), {:status, Validate.exec(args)}) end)

    assert_received {:status, :ok}

    assert output =~
             "Command #{inspect(Capture)} declares no :observables - event coverage not verified"
  end
end
