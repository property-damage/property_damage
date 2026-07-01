defmodule GiteaBench.WebhookInjector do
  @moduledoc """
  Receives the SUT's real `issues` (closed) webhook and pushes it into the run's
  `EventQueue` as an `IssueClosedWebhook` — the injector channel P9 exercises.

  ## How a live Gitea webhook reaches the run

  `PropertyDamage` starts a fresh `EventQueue` per run and calls `setup/1` with
  only `%{event_queue: queue}` (no adapter config), then `teardown/1` with `%{}`
  (not the `setup/1` context). Two consequences shape this design:

    * The injector self-sources Gitea credentials / ports from `:gitea_bench`
      application config, not from the run.
    * A single Bandit listener is started once and kept up across runs (the run
      process owns it; the OS reclaims the port when the test VM exits), because
      `teardown/1` cannot receive a per-run listener handle to stop. Each run
      instead registers its `{queue, token}` in `#{__MODULE__}.Registry`; the
      listener routes an inbound POST to the *current* run's queue only when the
      URL token matches. A retried delivery from a previous run carries a stale
      token and is dropped, so deliveries never leak across runs.

  On each `setup/1` we delete every admin hook and create exactly one **system
  webhook** (fires for all repositories) pointing at `/hook/<token>`, so no repo
  ever accumulates duplicate hooks (which would break the "at most one" safety
  assertion). System-webhook creation via the admin API requires gitea 1.24+,
  which is why the demo runs against the dedicated `gitea-webhook` instance.
  """

  use PropertyDamage.Adapter.Injector

  alias GiteaBench.Events.IssueClosedWebhook
  alias GiteaBench.Gitea
  alias GiteaBench.WebhookInjector.Registry

  @emits [IssueClosedWebhook]

  @impl true
  def setup(%{event_queue: event_queue}) do
    config = webhook_config()
    client = Gitea.new(config)
    :ok = Gitea.ensure_ready(client)
    :ok = Gitea.delete_all_admin_hooks(client)

    Registry.ensure_started()
    ensure_listener(config.listen_port)

    token = gen_token()
    Registry.put(queue: event_queue, token: token)

    callback_url = "http://#{config.callback_host}:#{config.listen_port}/hook/#{token}"
    :ok = Gitea.create_system_webhook(client, callback_url)

    {:ok, %{token: token}}
  end

  @impl true
  def teardown(_context) do
    # Drop the current queue so a late/retried delivery arriving between runs is
    # ignored. The listener stays up for the next run.
    if Process.whereis(Registry), do: Registry.put(queue: nil)
    :ok
  end

  @impl true
  def to_event(%{
        "action" => "closed",
        "repository" => %{"full_name" => full_name},
        "issue" => %{"number" => number}
      }) do
    {:ok, %IssueClosedWebhook{full_name: full_name, number: number}}
  end

  def to_event(_payload), do: :skip

  @doc false
  # Called by the Plug for each inbound POST. Only the current run's token is
  # honored; anything else (stale token, no active run, unparseable, irrelevant
  # action) is silently dropped.
  def deliver(token, body) do
    case Registry.get() do
      %{token: ^token, queue: queue} when is_pid(queue) ->
        with {:ok, payload} <- Jason.decode(body),
             {:ok, event} <- to_event(payload) do
          PropertyDamage.EventQueue.push(queue, __MODULE__, event)
        else
          _ -> :ok
        end

      _ ->
        :ok
    end
  end

  # --- listener lifecycle ----------------------------------------------------

  defp ensure_listener(port) do
    case Registry.get() do
      %{listener: pid} when is_pid(pid) ->
        if Process.alive?(pid), do: :ok, else: start_listener(port)

      _ ->
        start_listener(port)
    end
  end

  defp start_listener(port) do
    {:ok, pid} =
      Bandit.start_link(plug: __MODULE__.Router, scheme: :http, ip: {0, 0, 0, 0}, port: port)

    Registry.put(listener: pid)
    :ok
  end

  defp gen_token, do: Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)

  defp webhook_config do
    %{
      base_url: Application.fetch_env!(:gitea_bench, :webhook_url),
      admin_user: Application.fetch_env!(:gitea_bench, :admin_user),
      admin_password: Application.fetch_env!(:gitea_bench, :admin_password),
      listen_port: Application.fetch_env!(:gitea_bench, :webhook_listen_port),
      callback_host: Application.fetch_env!(:gitea_bench, :webhook_callback_host)
    }
  end

  defmodule Registry do
    @moduledoc false
    # Holds the current run's {queue, token} and the shared listener pid. Owned by
    # the run/test process (linked), so it survives across runs and dies with it.
    use Agent

    def ensure_started do
      case Process.whereis(__MODULE__) do
        nil ->
          Agent.start_link(fn -> %{queue: nil, token: nil, listener: nil} end, name: __MODULE__)

        pid ->
          {:ok, pid}
      end
    end

    def put(fields), do: Agent.update(__MODULE__, &Map.merge(&1, Map.new(fields)))
    def get, do: Agent.get(__MODULE__, & &1)
  end

  defmodule Router do
    @moduledoc false
    use Plug.Router

    plug(:match)
    plug(:dispatch)

    post "/hook/:token" do
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      GiteaBench.WebhookInjector.deliver(token, body)
      send_resp(conn, 200, "ok")
    end

    match _ do
      send_resp(conn, 200, "ignored")
    end
  end
end
