# Writes real failure pages and their index into a directory, for the browser
# specs to open over file://.
#
#     mix run test/browser/generate_pages.exs DIR
#
# Two small models fail in different ways: one on a check, one on an adapter
# error. The page of the check failure also gets an explanation, applied with
# `mix pd.explain --apply`, so the Explanation tab and its citations exist.

defmodule BrowserPages.Deposited do
  @moduledoc false
  defstruct [:amount]
end

defmodule BrowserPages.Pinged do
  @moduledoc false
  defstruct [:n]
end

defmodule BrowserPages.Deposit do
  @moduledoc "Puts a small amount into the account."
  use PropertyDamage.Command
  defstruct [:amount]

  @impl true
  def generator(overrides \\ %{}) do
    %{amount: StreamData.integer(1..9)}
    |> PropertyDamage.Generator.merge_overrides(overrides)
    |> StreamData.fixed_map()
  end
end

defmodule BrowserPages.Ping do
  @moduledoc "Asks the service whether it is up."
  use PropertyDamage.Command
  defstruct [:n]

  @impl true
  def generator(overrides \\ %{}) do
    %{n: StreamData.constant(0)}
    |> PropertyDamage.Generator.merge_overrides(overrides)
    |> StreamData.fixed_map()
  end
end

defmodule BrowserPages.DepositFirst do
  @moduledoc "Puts the first part of a split deposit into the account."
  use PropertyDamage.Command
  defstruct [:amount]

  @impl true
  def generator(overrides \\ %{}) do
    %{amount: StreamData.integer(1..9)}
    |> PropertyDamage.Generator.merge_overrides(overrides)
    |> StreamData.fixed_map()
  end
end

defmodule BrowserPages.DepositRest do
  @moduledoc "Puts the rest of a split deposit into the account."
  use PropertyDamage.Command
  defstruct [:amount]

  @impl true
  def generator(overrides \\ %{}) do
    %{amount: StreamData.integer(1..9)}
    |> PropertyDamage.Generator.merge_overrides(overrides)
    |> StreamData.fixed_map()
  end
end

defmodule BrowserPages.Steps do
  @moduledoc "Counts the commands of a sequence."
  @behaviour PropertyDamage.Model.Projection

  @impl true
  def init, do: %{count: 0}

  @impl true
  def apply(state, %BrowserPages.Deposit{}), do: %{state | count: state.count + 1}
  def apply(state, %BrowserPages.Ping{}), do: %{state | count: state.count + 1}
  def apply(state, %BrowserPages.DepositFirst{}), do: %{state | count: state.count + 1}
  def apply(state, %BrowserPages.DepositRest{}), do: %{state | count: state.count + 1}
  def apply(state, _other), do: state
end

defmodule BrowserPages.Ledger do
  @moduledoc "Keeps the running total of deposits and holds it under a limit."
  use PropertyDamage.Model.Projection

  @impl true
  def init, do: %{total: 0}

  @impl true
  def apply(state, %BrowserPages.Deposited{amount: amount}),
    do: %{state | total: state.total + amount}

  def apply(state, _other), do: state

  @check every: BrowserPages.Deposited
  def total_under_limit(state, _event) do
    state.total <= 8 or PropertyDamage.fail!("total passed the limit", total: state.total)
  end
end

defmodule BrowserPages.AccountModel do
  @moduledoc "Deposits into an account whose total must stay at or under 8."
  use PropertyDamage.Model

  @impl true
  def commands, do: [BrowserPages.Deposit]

  @impl true
  def command_sequence_projection, do: BrowserPages.Steps

  @impl true
  def check_projections, do: [BrowserPages.Ledger]
end

defmodule BrowserPages.ServiceModel do
  @moduledoc "Pings a service that stops answering after its first reply."
  use PropertyDamage.Model

  @impl true
  def commands, do: [{BrowserPages.Ping, overrides: &number/1}]

  # Each ping carries its position in the sequence.
  defp number(state), do: %{n: state.count}

  @impl true
  def command_sequence_projection, do: BrowserPages.Steps
end

defmodule BrowserPages.Adapter do
  @moduledoc "Answers each command from memory; a Ping fails once the service is down."
  use PropertyDamage.Adapter

  @impl true
  def setup(config), do: {:ok, config}

  @impl true
  def teardown(_ctx), do: :ok

  # The tenant "dave" books every deposit one too high, so it differs from its reference.
  @impl true
  def execute(%BrowserPages.Deposit{amount: amount}, %{tenant: "dave"}, _runtime),
    do: {:ok, [%BrowserPages.Deposited{amount: amount + 1}]}

  def execute(%BrowserPages.Deposit{amount: amount}, _ctx, _runtime),
    do: {:ok, [%BrowserPages.Deposited{amount: amount}]}

  def execute(%{__struct__: part, amount: amount}, %{tenant: "dave"}, _runtime)
      when part in [BrowserPages.DepositFirst, BrowserPages.DepositRest],
      do: {:ok, [%BrowserPages.Deposited{amount: amount + 1}]}

  def execute(%{__struct__: part, amount: amount}, _ctx, _runtime)
      when part in [BrowserPages.DepositFirst, BrowserPages.DepositRest],
      do: {:ok, [%BrowserPages.Deposited{amount: amount}]}

  def execute(%BrowserPages.Ping{n: 0}, _ctx, _runtime),
    do: {:ok, [%BrowserPages.Pinged{n: 0}]}

  def execute(%BrowserPages.Ping{}, _ctx, _runtime), do: {:error, :service_down}
end

defmodule BrowserPages.Total do
  @moduledoc "Sums the deposits of a sequence and offers the sum for comparison."
  use PropertyDamage.Model.Projection

  @impl true
  def init, do: %{total: 0}

  @impl true
  def apply(state, %BrowserPages.Deposited{amount: amount}),
    do: %{state | total: state.total + amount}

  def apply(state, _other), do: state

  @compare every: :end
  def total(state, _root), do: state.total
end

defmodule BrowserPages.PairModel do
  @moduledoc "Deposits on two targets that book the same amount differently."
  use PropertyDamage.Model

  @impl true
  def commands, do: [BrowserPages.Deposit]

  @impl true
  def command_sequence_projection, do: BrowserPages.Steps

  @impl true
  def check_projections, do: [BrowserPages.Total]
end

defmodule BrowserPages.ExpandModel do
  @moduledoc """
  Deposits whose route depends on the amount: a small one runs as itself under
  a listed entry, a middle one splits into two parts, a large one is dropped.
  """
  use PropertyDamage.Model

  alias BrowserPages.{Deposit, DepositFirst, DepositRest}

  @impl true
  def commands, do: [Deposit]

  @impl true
  def command_sequence_projection, do: BrowserPages.Steps

  @impl true
  def check_projections, do: [BrowserPages.Total]

  @impl true
  def expansions, do: [{Deposit, &route/2}]

  def route(%Deposit{amount: amount} = deposit, _state) when amount <= 3,
    do: [{[deposit], doc: "as is"}]

  def route(%Deposit{amount: amount}, _state) when amount <= 6 do
    first = div(amount, 2)

    [
      {[
         {DepositFirst, overrides: %{amount: first}},
         {DepositRest, overrides: %{amount: amount - first}}
       ], doc: "in two parts"}
    ]
  end

  def route(%Deposit{}, _state), do: [{[], doc: "not at all"}]
end

defmodule BrowserPages.Generate do
  @moduledoc false

  alias PropertyDamage.FailureReport.HTML

  def main([dir]) do
    dir = Path.expand(dir)
    File.rm_rf!(dir)
    File.mkdir_p!(dir)

    check_page = run!(BrowserPages.AccountModel, "alice", 11, dir)
    run!(BrowserPages.ServiceModel, "bob", 12, dir)
    run!(BrowserPages.PairModel, ["carol", "dave"], 13, dir)
    run!(BrowserPages.ExpandModel, ["carol", "dave"], 20, dir, shrink: false)

    explain!(check_page, dir)

    pages = dir |> File.ls!() |> Enum.reject(&(&1 == "index.html")) |> Enum.sort()
    IO.puts("wrote #{length(pages)} pages and index.html into #{dir}")
  end

  def main(_args), do: Mix.raise("usage: mix run test/browser/generate_pages.exs DIR")

  # Runs the model until it fails and returns the page the run wrote.
  defp run!(model, names, seed, dir, extra \\ []) do
    before = File.ls!(dir)

    targets =
      for name <- List.wrap(names),
          do: {BrowserPages.Adapter, name: name, config: %{tenant: name}}

    result =
      PropertyDamage.run(
        [
          model: model,
          targets: targets,
          max_runs: 20,
          max_commands: 6,
          seed: seed,
          replay_dir: false,
          report_html: dir
        ] ++ extra
      )

    with {:error, %PropertyDamage.FailureReport{}} <- result,
         [page] <- File.ls!(dir) -- (before ++ ["index.html"]) do
      Path.join(dir, page)
    else
      other -> Mix.raise("#{inspect(model)} did not write one failure page: #{inspect(other)}")
    end
  end

  # Applies an explanation that cites ids taken from the page's own bundle.
  defp explain!(page, dir) do
    bundle = page |> File.read!() |> bundle()
    entry = bundle["listing"] |> Enum.flat_map(& &1["steps"]) |> Enum.find(&(&1["entries"] != []))
    event = hd(entry["entries"])["id"]
    failure = hd(bundle["failure"]["fields"])["id"]
    section = hd(bundle["sections"])["id"]
    module = Enum.find(bundle["modules"], &String.ends_with?(&1["module"], "Ledger"))
    source = "source:#{module["module"]}:1-3"

    explanation = %{
      "summary" => [
        %{"text" => "A deposit pushed the total over its limit.", "cites" => [failure]}
      ],
      "hypotheses" => [
        %{
          "rank" => 1,
          "likelihood" => "likely",
          "claim" => "The ledger check ran after a deposit that crossed the limit.",
          "evidence" => [entry["id"], event, source],
          "next_steps" => ["Read the total in the Failure section."]
        }
      ],
      "talking_points" => [%{"text" => "The limit is part of the model.", "cites" => [section]}]
    }

    path = Path.join(dir, "explanation.json")
    File.write!(path, Jason.encode!(explanation))
    Mix.Task.rerun("pd.explain", [page, "--apply", path])
    File.rm!(path)
    {:ok, _index} = HTML.write_index(dir)
  end

  defp bundle(html) do
    [_, json] =
      Regex.run(~r{<script type="application/json" id="pd-bundle">(.*?)</script>}s, html)

    Jason.decode!(json)
  end
end

BrowserPages.Generate.main(System.argv())
