defmodule GiteaBench.Gitea do
  @moduledoc """
  Shared Gitea client: readiness, per-run reset, REST mutations, and **neutral
  observation reads** used to build events.

  Both adapters build their events from the same observers here, so the only thing
  that varies between the API and UI transports is *how the mutation is performed*.
  The differential oracle then reduces to a precise question: after the same intent
  is carried out via REST versus via the browser, is the resulting forge state
  identical? Observation is via the REST read API for both (a transport-neutral
  way to inspect state); only the mutating action differs by transport.

  Every created user is given the same known password so an adapter can act *as*
  that user (Gitea's UI can only create a repo under the acting account, so true
  API/UI parity requires both transports to authenticate as the repo owner).
  """

  alias GiteaBench.Events.{
    IssueClosed,
    IssueCreated,
    LabelAssigned,
    LabelCreated,
    RepoCreated,
    UserCreated
  }

  @user_password "Pd-User-12345"

  defstruct [:base_url, :admin_user, :admin_password]

  @type t :: %__MODULE__{base_url: String.t(), admin_user: String.t(), admin_password: String.t()}

  @doc "Build a client from an adapter config map (`:base_url`, `:admin_user`, `:admin_password`)."
  def new(config) do
    %__MODULE__{
      base_url: Map.fetch!(config, :base_url),
      admin_user: Map.get(config, :admin_user, "pdadmin"),
      admin_password: Map.get(config, :admin_password, "Pd-Admin-12345")
    }
  end

  @doc "The known password for a created (non-admin) user."
  def user_password, do: @user_password

  @doc "Basic-auth tuple for acting as `user` (admin password for the admin, else the shared user password)."
  def auth_for(%__MODULE__{admin_user: admin, admin_password: admin_pw}, user) do
    pw = if user == admin, do: admin_pw, else: @user_password
    {:basic, "#{user}:#{pw}"}
  end

  # --- lifecycle -------------------------------------------------------------

  @doc "Poll `/api/healthz` until the instance serves, or raise after the timeout."
  def ensure_ready(%__MODULE__{base_url: base_url}, timeout_ms \\ 30_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_ensure_ready(base_url, deadline)
  end

  defp do_ensure_ready(base_url, deadline) do
    case Req.request(method: :get, url: base_url <> "/api/healthz", retry: false) do
      {:ok, %{status: 200}} ->
        :ok

      _ ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(300)
          do_ensure_ready(base_url, deadline)
        else
          raise "Gitea at #{base_url} not ready within timeout"
        end
    end
  end

  @doc """
  Reset the instance to a clean slate by purging every non-admin user (which
  cascades to their repos, issues and labels). Run in each adapter's `setup/1`
  so reusing a long-lived container across runs never leaks state between runs,
  and both transports start every run from identical, empty forges.
  """
  def reset!(%__MODULE__{admin_user: admin} = client) do
    {:ok, 200, users} = req(:get, client, "/admin/users?limit=50", auth: admin_auth(client))

    for %{"login" => login} <- users, login != admin do
      {:ok, _status, _body} =
        req(:delete, client, "/admin/users/#{login}?purge=true", auth: admin_auth(client))
    end

    :ok
  end

  # --- system webhooks (P9 injector) -----------------------------------------

  @doc """
  Delete every admin-level (system/default) webhook on the instance.

  Run in the injector's `setup/1` before creating our own, so repeated runs never
  accumulate hooks (which would make the "exactly one webhook" invariant see
  duplicate deliveries). Requires a gitea instance that exposes the admin hooks
  API (1.24+ for system webhooks).
  """
  def delete_all_admin_hooks(%__MODULE__{} = client) do
    {:ok, 200, hooks} = req(:get, client, "/admin/hooks?limit=50", auth: admin_auth(client))

    for %{"id" => id} <- hooks do
      {:ok, _status, _body} = req(:delete, client, "/admin/hooks/#{id}", auth: admin_auth(client))
    end

    :ok
  end

  @doc """
  Create a single system webhook (fires for every repository, existing or new)
  that POSTs the native gitea `issues` event to `callback_url`.

  `is_system_webhook` lives in the string-valued `config` map (gitea's hook config
  is `map[string]string`), and only takes effect from gitea 1.24 on.
  """
  def create_system_webhook(%__MODULE__{} = client, callback_url) do
    body = %{
      type: "gitea",
      active: true,
      events: ["issues"],
      config: %{
        "url" => callback_url,
        "content_type" => "json",
        "is_system_webhook" => "true"
      }
    }

    expect(req(:post, client, "/admin/hooks", json: body, auth: admin_auth(client)), [201])
  end

  # --- mutations (API transport) ---------------------------------------------

  def create_user(client, login, email) do
    body = %{username: login, email: email, password: @user_password, must_change_password: false}
    expect(req(:post, client, "/admin/users", json: body, auth: admin_auth(client)), [201])
  end

  def create_repo(client, owner, name) do
    body = %{name: name, auto_init: false, private: false}
    expect(req(:post, client, "/user/repos", json: body, auth: auth_for(client, owner)), [201])
  end

  @doc "Create an issue and return `{:ok, number}` with the SUT-assigned issue number."
  def create_issue(client, owner, repo, title) do
    case req(:post, client, "/repos/#{owner}/#{repo}/issues",
           json: %{title: title},
           auth: auth_for(client, owner)
         ) do
      {:ok, 201, body} -> {:ok, body["number"]}
      {:ok, status, _body} -> {:error, {:unexpected_status, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  def create_label(client, owner, repo, name, color) do
    body = %{name: name, color: color}

    expect(
      req(:post, client, "/repos/#{owner}/#{repo}/labels",
        json: body,
        auth: auth_for(client, owner)
      ),
      [201]
    )
  end

  def assign_label(client, owner, repo, number, label_name) do
    label_id = find_label_id!(client, owner, repo, label_name)
    body = %{labels: [label_id]}

    expect(
      req(:post, client, "/repos/#{owner}/#{repo}/issues/#{number}/labels",
        json: body,
        auth: auth_for(client, owner)
      ),
      [200]
    )
  end

  def close_issue(client, owner, repo, number) do
    body = %{state: "closed"}

    expect(
      req(:patch, client, "/repos/#{owner}/#{repo}/issues/#{number}",
        json: body,
        auth: auth_for(client, owner)
      ),
      [200, 201]
    )
  end

  # --- observers (neutral reads; build events) -------------------------------

  def user_event(client, requested_login) do
    case req(:get, client, "/users/#{requested_login}", auth: admin_auth(client)) do
      {:ok, 200, b} ->
        %UserCreated{requested_login: requested_login, login: b["login"], id: b["id"]}

      _ ->
        %UserCreated{requested_login: requested_login, login: nil, id: nil}
    end
  end

  def repo_event(client, owner, requested_name) do
    case req(:get, client, "/repos/#{owner}/#{requested_name}", auth: admin_auth(client)) do
      {:ok, 200, b} ->
        %RepoCreated{
          owner: owner,
          requested_name: requested_name,
          name: b["name"],
          full_name: b["full_name"],
          id: b["id"]
        }

      _ ->
        %RepoCreated{
          owner: owner,
          requested_name: requested_name,
          name: nil,
          full_name: nil,
          id: nil
        }
    end
  end

  def issue_event(client, full_name, number, requested_title) do
    {owner, repo} = GiteaBench.split_full_name(full_name)

    case req(:get, client, "/repos/#{owner}/#{repo}/issues/#{number}", auth: admin_auth(client)) do
      {:ok, 200, b} ->
        %IssueCreated{
          full_name: full_name,
          number: number,
          requested_title: requested_title,
          title: b["title"],
          id: b["id"]
        }

      _ ->
        %IssueCreated{
          full_name: full_name,
          number: number,
          requested_title: requested_title,
          title: nil,
          id: nil
        }
    end
  end

  def label_event(client, full_name, requested_name) do
    {owner, repo} = GiteaBench.split_full_name(full_name)

    {:ok, 200, labels} =
      req(:get, client, "/repos/#{owner}/#{repo}/labels", auth: admin_auth(client))

    case Enum.find(labels, fn l -> l["name"] == requested_name end) do
      nil ->
        %LabelCreated{
          full_name: full_name,
          requested_name: requested_name,
          name: nil,
          color: nil,
          id: nil
        }

      l ->
        %LabelCreated{
          full_name: full_name,
          requested_name: requested_name,
          name: l["name"],
          color: l["color"],
          id: l["id"]
        }
    end
  end

  def label_assigned_event(client, full_name, number, requested_label) do
    {owner, repo} = GiteaBench.split_full_name(full_name)
    observed = observed_labels(client, owner, repo, number)

    %LabelAssigned{
      full_name: full_name,
      number: number,
      requested_label: requested_label,
      labels: observed
    }
  end

  def issue_closed_event(client, full_name, number) do
    {owner, repo} = GiteaBench.split_full_name(full_name)

    case req(:get, client, "/repos/#{owner}/#{repo}/issues/#{number}", auth: admin_auth(client)) do
      {:ok, 200, b} -> %IssueClosed{full_name: full_name, number: number, state: b["state"]}
      _ -> %IssueClosed{full_name: full_name, number: number, state: nil}
    end
  end

  @doc "The issue's current label names, sorted (observed via the read API)."
  def observed_labels(client, owner, repo, number) do
    case req(:get, client, "/repos/#{owner}/#{repo}/issues/#{number}/labels",
           auth: admin_auth(client)
         ) do
      {:ok, 200, labels} -> labels |> Enum.map(& &1["name"]) |> Enum.sort()
      _ -> []
    end
  end

  @doc "The numeric id of a label by name (or nil), used by the UI dropdown."
  def label_id(client, owner, repo, label_name) do
    case req(:get, client, "/repos/#{owner}/#{repo}/labels", auth: admin_auth(client)) do
      {:ok, 200, labels} ->
        case Enum.find(labels, fn l -> l["name"] == label_name end) do
          %{"id" => id} -> id
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp find_label_id!(client, owner, repo, label_name) do
    {:ok, 200, labels} =
      req(:get, client, "/repos/#{owner}/#{repo}/labels", auth: admin_auth(client))

    %{"id" => id} = Enum.find(labels, fn l -> l["name"] == label_name end)
    id
  end

  # --- HTTP plumbing ---------------------------------------------------------

  defp admin_auth(%__MODULE__{admin_user: admin} = client), do: auth_for(client, admin)

  defp req(method, %__MODULE__{base_url: base_url}, path, opts) do
    request =
      [method: method, url: base_url <> "/api/v1" <> path, auth: opts[:auth], retry: false]
      |> maybe_put(:json, opts[:json])

    case Req.request(request) do
      {:ok, %{status: status, body: body}} -> {:ok, status, body}
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  # Treat the REST response as a transport observation: an expected status is a
  # success (the observers read back the real state); anything else is a genuine
  # transport/SUT failure surfaced to PropertyDamage as {:error, _}.
  defp expect({:ok, status, _body}, oks) when is_list(oks) do
    if status in oks, do: :ok, else: {:error, {:unexpected_status, status}}
  end

  defp expect({:error, reason}, _oks), do: {:error, reason}
end
