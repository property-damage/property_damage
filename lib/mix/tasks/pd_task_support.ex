defmodule PropertyDamage.Mix.TaskSupport do
  @moduledoc false
  # Shared helpers for the `mix pd.*` tasks. Not a Mix.Task itself (no `use
  # Mix.Task`), so it is never discovered/listed as a task.

  @doc """
  Load the current Mix project app's modules (and its declared dependency apps')
  so their atoms and struct definitions exist before a `.pd` failure file is
  decoded.

  A `.pd` file is decoded with `:erlang.binary_to_term(bin, [:safe])`, which
  refuses to materialise atoms that are not already known to the VM. Saved
  failures reference the user's own command/event struct modules; unless those
  modules have been loaded into this VM, their atoms are unknown and the decode
  fails with `{:error, :unsafe_terms}`. `Mix.Task.run("compile")` writes the
  `.beam` files but does not load them, so we load them explicitly here.

  This preserves the `:safe` decode posture: we only make the SUT's own atoms
  known, we do not relax the decoder.
  """
  @spec load_project_modules() :: :ok
  def load_project_modules do
    case Mix.Project.config()[:app] do
      nil ->
        :ok

      app ->
        # Loading the app makes its `:modules` and `:applications` specs
        # available; each `Code.ensure_loaded/1` then registers those modules'
        # atoms (including struct names) with the VM.
        Application.load(app)
        ensure_app_modules_loaded(app)

        for dep <- dependency_apps(app) do
          ensure_app_modules_loaded(dep)
        end

        :ok
    end
  end

  # The SUT's declared runtime dependencies. Scoped to the project's own deps
  # (not every loaded application) so this stays cheap and robust: those are the
  # apps whose structs a saved failure might reference.
  defp dependency_apps(app) do
    (Application.spec(app, :applications) || []) ++
      (Application.spec(app, :included_applications) || [])
  end

  defp ensure_app_modules_loaded(app) do
    (Application.spec(app, :modules) || [])
    |> Enum.each(&Code.ensure_loaded/1)
  end
end
