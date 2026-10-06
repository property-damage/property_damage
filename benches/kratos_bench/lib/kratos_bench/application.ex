defmodule KratosBench.Application do
  @moduledoc """
  Owns the processes that must outlive every run of a campaign: the
  `KratosBench.RegistrationMock.Hub` and the supervisor the mock's web_hook
  listener runs under.

  `PropertyDamage.run/1` calls the adapter's `setup/1` once per run, in a process
  that exits when the run ends, so the listener cannot be that process's child.
  The listener starts on the first run's `setup/1` (it needs the port from the
  target config) and stays up until the application stops.
  """

  use Application

  alias KratosBench.RegistrationMock

  @impl true
  def start(_type, _args) do
    children = [
      RegistrationMock.Hub,
      {DynamicSupervisor, name: RegistrationMock.ListenerSupervisor, strategy: :one_for_one}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: KratosBench.Supervisor)
  end
end
