defmodule ObanBench.Events do
  @moduledoc "Events describing the async work as it progresses."

  defmodule Enqueued do
    @moduledoc "A job was enqueued for `counter` (synchronous result of the command)."
    defstruct [:counter, :job_id]
  end

  defmodule Incremented do
    @moduledoc """
    A resource poller observed the counter's current value in the SUT.

    `value` is what the database actually held at poll time. These events
    arrive asynchronously, after the command returns, as Oban drains the queue.
    """
    defstruct [:counter, :value]
  end
end

defmodule ObanBench.Commands.Increment do
  @moduledoc "Enqueue an async job that increments a named counter by one."
  @behaviour PropertyDamage.Command

  import PropertyDamage.Generator, only: [merge_overrides: 2]

  defstruct [:counter]

  @impl true
  def generator(overrides \\ %{}) do
    %{counter: StreamData.member_of(ObanBench.counters())}
    |> merge_overrides(overrides)
    |> StreamData.fixed_map()
  end
end
