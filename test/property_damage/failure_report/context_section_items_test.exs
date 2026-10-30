defmodule PropertyDamage.FailureReport.ContextSectionItemsTest do
  # The items of the "What this checks" section for each failure kind: which
  # labels print, with which names, in which order, and which kinds print no
  # `Command` item.
  use ExUnit.Case, async: false

  alias PropertyDamage.{Failure, FailureReport}
  alias PropertyDamage.Test.Compare
  alias PropertyDamage.Test.ContextSection, as: U
  alias PropertyDamage.Test.ReportLayout, as: L

  setup_all do
    u = U.define()
    eventual = U.define(checks: :eventual)
    setup = U.define(setup: true)

    on_exit(fn -> Enum.each([u, eventual, setup], &U.purge/1) end)

    {:ok, u: u, eventual: eventual, setup: setup}
  end

  # `[{label, name}]` of a report's section; the meaning item has no name, and
  # an item whose label stands alone has none either.
  defp outline(report) do
    [meaning | rest] = report |> U.body!(:terminal) |> U.items()
    [{meaning.label, nil} | Enum.map(rest, &{&1.label, &1.head})]
  end

  defp meaning_of(report), do: U.kind_label(U.kind(report))

  describe "a property did not hold" do
    test "check_failed: the check, its projection, the property, then the command", %{u: u} do
      report = U.check_failed(u)

      assert outline(report) == [
               {"Check failed", nil},
               {"Model", inspect(u.model)},
               {"Check", "#{inspect(u.ledger)}.assert_settled_not_negative/2"},
               {"Projection", inspect(u.ledger)},
               {"Property", "no_negative_settlement"},
               {"Command", inspect(u.pay)}
             ]
    end

    test "check_failed: the property prints the description of the invariant", %{u: u} do
      item = u |> U.check_failed() |> U.body!(:terminal) |> U.item!("Property")

      assert U.below_label(item) == [U.doc(:invariant)]
    end

    test "poll_timeout: the check, its projection, then the command; no property", %{
      eventual: u
    } do
      report = U.poll_timeout(u)

      assert outline(report) == [
               {"Poll timeout", nil},
               {"Model", inspect(u.model)},
               {"Check", "#{inspect(u.eventual)}.assert_settles_in_time/2"},
               {"Projection", inspect(u.eventual)},
               {"Command", inspect(u.pay)}
             ]
    end

    test "projection_violation: the projection is the subject, then the command", %{u: u} do
      report = U.projection_violation(u)

      assert outline(report) == [
               {"Projection violation", nil},
               {"Model", inspect(u.model)},
               {"Projection", inspect(u.ledger)},
               {"Command", inspect(u.pay)}
             ]
    end

    test "a kind with no subject prints the model and the command" do
      report = L.report(:idempotency)

      assert outline(report) == [
               {"Idempotency violation", nil},
               {"Model", inspect(Compare.PayModel)},
               {"Command", inspect(Compare.Pay)}
             ]
    end
  end

  describe "targets disagreed or were too slow" do
    test "diverged: observation, relation, other observation, projection, command", %{u: u} do
      report = U.diverged(u)

      assert outline(report) == [
               {"Diverged", nil},
               {"Model", inspect(u.model)},
               {"Observation", "#{inspect(u.ledger)}.a_total/2"},
               {"Relation", "#{inspect(u.relations)}.same_total/2"},
               {"Also differed", "#{inspect(u.ledger)}.b_fees/2"},
               {"Projection", inspect(u.ledger)},
               {"Command", inspect(u.pay)}
             ]
    end

    test "did_not_converge: observation, relation, projection, command", %{u: u} do
      report = U.did_not_converge(u)

      assert outline(report) == [
               {"Did not converge", nil},
               {"Model", inspect(u.model)},
               {"Observation", "#{inspect(u.ledger)}.a_total/2"},
               {"Relation", "#{inspect(u.relations)}.same_total/2"},
               {"Projection", inspect(u.ledger)},
               {"Command", inspect(u.pay)}
             ]
    end

    test "latency_exceeded: the model and no command, since no step is marked", %{u: u} do
      report = U.latency_exceeded(u)

      assert FailureReport.failure_step(report) == nil
      assert outline(report) == [{"Latency exceeded", nil}, {"Model", inspect(u.model)}]
    end
  end

  describe "unable to test the system" do
    test "setup_failed by a setup command: that command is the subject, once", %{setup: u} do
      report = U.setup_failed_command(u)

      assert outline(report) == [
               {"Setup failed", nil},
               {"Model", inspect(u.model)},
               {"Command", inspect(u.login)}
             ]
    end

    test "setup_failed by the adapter's setup: no subject and no command", %{u: u} do
      report = U.setup_failed_adapter(u)

      assert outline(report) == [{"Setup failed", nil}, {"Model", inspect(u.model)}]
    end

    test "adapter_error: the failing command is the subject, not repeated last", %{u: u} do
      report = U.adapter_error(u)

      assert outline(report) == [
               {"Adapter error", nil},
               {"Model", inspect(u.model)},
               {"Command", inspect(u.pay)}
             ]
    end

    test "a framework kind prints the model and the command of the marked step", %{u: u} do
      real = U.check_failed(u)
      failure = Failure.unknown(:weird_term)
      report = %{real | failure_reason: failure, kind: FailureReport.kind_of(failure)}

      assert %{command: %{__struct__: pay}} = FailureReport.failure_step(report)
      assert pay == u.pay

      assert outline(report) == [
               {"Unknown", nil},
               {"Model", inspect(u.model)},
               {"Command", inspect(u.pay)}
             ]
    end

    test "poll_error: no check name and no step, so the meaning and the model only", %{u: u} do
      report = U.poll_error(u)

      assert FailureReport.failure_step(report) == nil
      assert FailureReport.check_name(report) == nil
      assert outline(report) == [{"Poll error", nil}, {"Model", inspect(u.model)}]
    end
  end

  test "the first item of every report names the kind in words", %{u: u} do
    for report <- [U.check_failed(u), U.diverged(u), U.adapter_error(u), U.latency_exceeded(u)] do
      assert [%{label: label} | _] = report |> U.body!(:terminal) |> U.items()
      assert label == meaning_of(report)
    end
  end
end
