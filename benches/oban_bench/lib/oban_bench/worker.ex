defmodule ObanBench.IncrementWorker do
  @moduledoc """
  The async work the bench exercises: increment a named counter by one.

  This is the faithful (correct) worker. The seeded-bug test swaps in a
  variant that completes without performing the increment.
  """
  use Oban.Worker, queue: :bench, max_attempts: 3

  @impl true
  def perform(%Oban.Job{args: %{"counter" => name}}) do
    ObanBench.DB.increment(name)
  end
end
