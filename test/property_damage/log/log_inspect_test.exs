defmodule PropertyDamage.Log.LogInspectTest do
  # `inspect/2` of a report never raises. When `PD_LOG` does not parse, the
  # one-line summary it falls back to names the error, so the reader sees the
  # expected syntax instead of an unexplained short form. This module sets the
  # environment variable and restores it in `on_exit`, so it is `async: false`.
  use ExUnit.Case, async: false

  alias PropertyDamage.Test.LogFixtures, as: F

  @syntax "only:http,seed except:body"

  setup do
    F.compile!()
    previous = System.get_env("PD_LOG")
    System.delete_env("PD_LOG")

    on_exit(fn ->
      if previous, do: System.put_env("PD_LOG", previous), else: System.delete_env("PD_LOG")
    end)
  end

  test "an invalid PD_LOG makes the summary name the error and the syntax" do
    report = F.filter_report!()
    System.put_env("PD_LOG", "bogus:x")

    text = inspect(report, pretty: true)

    assert text =~ "#FailureReport<seed:"
    assert text =~ ~s("bogus:x")
    assert text =~ @syntax
  end

  test "without PD_LOG, a pretty inspect prints the report" do
    text = inspect(F.filter_report!(), pretty: true)

    assert text =~ "BUG DETECTED"
    refute text =~ "#FailureReport<seed:"
  end
end
