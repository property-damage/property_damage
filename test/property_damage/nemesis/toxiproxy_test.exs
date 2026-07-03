defmodule PropertyDamage.Nemesis.ToxiproxyTest do
  @moduledoc """
  Tests for the extracted `PropertyDamage.Nemesis.Toxiproxy` integration and the
  three network nemeses built on it.

  Covers:

    * the pure toxic builders (`toxics/1`) for each nemesis, including the
      `:full` partition producing TWO toxics (up + down);
    * the real HTTP path against a local ephemeral fixture (no docker, no deps) —
      both a direct `inject/2` call and, crucially, the ENGINE path where an
      adapter's `setup/1` return carries the Toxiproxy config (DR-038: on the
      pre-fix code the engine never reached the live path and stayed simulated);
    * restore of a `:full` partition issuing two DELETEs;
    * `:asymmetric` being gone from the partition vocabulary.
  """
  use ExUnit.Case, async: false

  alias PropertyDamage.Executor
  alias PropertyDamage.Nemesis.{NetworkLatency, NetworkPartition, PacketLoss}

  # ==========================================================================
  # Local HTTP fixture: records requests, replies 200. No inets httpd, no deps.
  # ==========================================================================

  defmodule Fixture do
    @moduledoc false

    def start do
      {:ok, listen} =
        :gen_tcp.listen(0, [:binary, packet: :http_bin, active: false, reuseaddr: true])

      {:ok, port} = :inet.port(listen)
      {:ok, agent} = Agent.start_link(fn -> [] end)
      acceptor = spawn_link(fn -> accept_loop(listen, agent) end)
      %{port: port, agent: agent, listen: listen, acceptor: acceptor}
    end

    def stop(%{listen: listen, agent: agent}) do
      :gen_tcp.close(listen)
      if Process.alive?(agent), do: Agent.stop(agent)
      :ok
    end

    @doc "Recorded requests, oldest first: [%{method, path, body}]."
    def requests(%{agent: agent}), do: Agent.get(agent, &Enum.reverse/1)

    def base_url(%{port: port}), do: "http://127.0.0.1:#{port}"

    defp accept_loop(listen, agent) do
      case :gen_tcp.accept(listen) do
        {:ok, socket} ->
          serve(socket, agent)
          accept_loop(listen, agent)

        {:error, :closed} ->
          :ok
      end
    end

    defp serve(socket, agent) do
      {method, path, headers} = read_head(socket, nil, nil, [])
      body = read_body(socket, content_length(headers))

      Agent.update(agent, fn reqs ->
        [%{method: method, path: path, body: body} | reqs]
      end)

      :gen_tcp.send(socket, "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}")
      :gen_tcp.close(socket)
    end

    defp read_head(socket, method, path, headers) do
      case :gen_tcp.recv(socket, 0, 5000) do
        {:ok, {:http_request, m, {:abs_path, p}, _v}} ->
          read_head(socket, to_string(m), to_string(p), headers)

        {:ok, {:http_header, _, name, _, value}} ->
          read_head(socket, method, path, [{header_name(name), to_string(value)} | headers])

        {:ok, :http_eoh} ->
          {method, path, headers}

        {:error, _} ->
          {method, path, headers}
      end
    end

    defp header_name(name) when is_atom(name), do: name |> Atom.to_string() |> String.downcase()
    defp header_name(name), do: name |> to_string() |> String.downcase()

    defp content_length(headers) do
      case List.keyfind(headers, "content-length", 0) do
        {_, v} -> String.to_integer(v)
        nil -> 0
      end
    end

    defp read_body(_socket, 0), do: ""

    defp read_body(socket, len) do
      :inet.setopts(socket, packet: :raw)

      case :gen_tcp.recv(socket, len, 5000) do
        {:ok, data} -> data
        {:error, _} -> ""
      end
    end
  end

  # ==========================================================================
  # Pure toxic builders
  # ==========================================================================

  describe "toxics/1 (pure builders)" do
    test "NetworkLatency builds one latency toxic" do
      assert [toxic] = NetworkLatency.toxics(%NetworkLatency{latency_ms: 250, jitter_ms: 10})
      assert toxic["name"] == "pd_latency"
      assert toxic["type"] == "latency"
      assert toxic["attributes"] == %{"latency" => 250, "jitter" => 10}
    end

    test "PacketLoss builds one timeout toxic with toxicity from loss_percent" do
      assert [toxic] = PacketLoss.toxics(%PacketLoss{loss_percent: 40})
      assert toxic["name"] == "pd_packet_loss"
      assert toxic["type"] == "timeout"
      assert toxic["toxicity"] == 0.4
      assert toxic["attributes"] == %{"timeout" => 0}
    end

    test "NetworkPartition :upstream / :downstream build one directional toxic" do
      assert [up] = NetworkPartition.toxics(%NetworkPartition{partition_type: :upstream})
      assert up["name"] == "pd_partition"
      assert up["type"] == "bandwidth"
      assert up["stream"] == "upstream"
      assert up["attributes"] == %{"rate" => 0}

      assert [down] = NetworkPartition.toxics(%NetworkPartition{partition_type: :downstream})
      assert down["stream"] == "downstream"
    end

    # RED-first (DR-038): a full bidirectional partition must be TWO toxics, one
    # per stream. The pre-fix code sent a single unqualified toxic (downstream by
    # Toxiproxy default), so requests still flowed.
    test "NetworkPartition :full builds TWO toxics, one per stream" do
      toxics = NetworkPartition.toxics(%NetworkPartition{partition_type: :full})

      assert length(toxics) == 2
      streams = toxics |> Enum.map(& &1["stream"]) |> Enum.sort()
      assert streams == ["downstream", "upstream"]

      for toxic <- toxics do
        assert toxic["type"] == "bandwidth"
        assert toxic["attributes"] == %{"rate" => 0}
      end

      names = toxics |> Enum.map(& &1["name"]) |> Enum.sort()
      assert names == ["pd_partition_down", "pd_partition_up"]
    end
  end

  # ==========================================================================
  # :asymmetric removal
  # ==========================================================================

  describe ":asymmetric is removed from the partition vocabulary" do
    test "the generator never emits :asymmetric" do
      commands = NetworkPartition.new!(%{}) |> StreamData.resize(20) |> Enum.take(100)
      types = commands |> Enum.map(& &1.partition_type) |> Enum.uniq() |> Enum.sort()
      assert types == [:downstream, :full, :upstream]
    end

    test "toxics/1 rejects an :asymmetric partition (no clause)" do
      # Built via struct/2 so the value isn't a struct literal the type checker
      # would narrow (it already knows :asymmetric is not a valid partition_type).
      bad = struct(NetworkPartition, partition_type: :asymmetric)

      assert_raise FunctionClauseError, fn -> NetworkPartition.toxics(bad) end
    end
  end

  # ==========================================================================
  # Live HTTP path (direct inject/2 with top-level config)
  # ==========================================================================

  describe "live injection against a real HTTP fixture" do
    setup do
      {:ok, _} = Application.ensure_all_started(:inets)
      fixture = Fixture.start()
      on_exit(fn -> Fixture.stop(fixture) end)
      %{fixture: fixture}
    end

    test "inject POSTs a real toxic and tags the event simulated: false", %{fixture: fixture} do
      ctx = %{toxiproxy: %{proxy_name: "svc", api_url: Fixture.base_url(fixture)}}

      {:ok, [event]} = NetworkLatency.inject(%NetworkLatency{latency_ms: 100}, ctx)
      assert event.simulated == false

      assert [%{method: "POST", path: "/proxies/svc/toxics"}] = Fixture.requests(fixture)
    end

    test "restore of a :full partition issues TWO DELETEs", %{fixture: fixture} do
      ctx = %{toxiproxy: %{proxy_name: "svc", api_url: Fixture.base_url(fixture)}}
      cmd = %NetworkPartition{partition_type: :full, injected_at: 0}

      {:ok, [%{simulated: false}]} = NetworkPartition.restore(cmd, ctx)

      deletes =
        fixture
        |> Fixture.requests()
        |> Enum.filter(&(&1.method == "DELETE"))
        |> Enum.map(& &1.path)
        |> Enum.sort()

      assert deletes == [
               "/proxies/svc/toxics/pd_partition_down",
               "/proxies/svc/toxics/pd_partition_up"
             ]
    end
  end

  # ==========================================================================
  # Engine path (DR-038 seam): config comes from the adapter's setup/1 return
  # ==========================================================================

  defmodule NoOp do
    @moduledoc false
    @behaviour PropertyDamage.Command
    defstruct []
    @impl true
    def generator(_overrides \\ %{}), do: StreamData.constant(%{})
  end

  defmodule Projection do
    @moduledoc false
    use PropertyDamage.Model.Projection
    @impl true
    def init, do: %{}
    @impl true
    def apply(state, _event), do: state
  end

  defmodule Model do
    @moduledoc false
    @behaviour PropertyDamage.Model
    @impl true
    def commands, do: [NoOp]
    @impl true
    def command_sequence_projection, do: Projection
  end

  # Adapter whose setup/1 return carries the Toxiproxy endpoint (DR-038). This is
  # the ONLY channel the engine offers, and the whole point of the fix.
  defmodule SeamAdapter do
    @moduledoc false
    use PropertyDamage.Adapter
    @impl true
    def setup(config), do: {:ok, %{toxiproxy: config[:toxiproxy]}}
    @impl true
    def teardown(_ctx), do: :ok
    @impl true
    def execute(%NoOp{}, _ctx, _runtime), do: {:ok, []}
  end

  describe "engine path: adapter setup/1 carries the config (DR-038 seam)" do
    setup do
      {:ok, _} = Application.ensure_all_started(:inets)
      fixture = Fixture.start()
      on_exit(fn -> Fixture.stop(fixture) end)
      %{fixture: fixture}
    end

    test "a nemesis run through PropertyDamage injects for real", %{fixture: fixture} do
      # Long duration so the fault does not auto-restore mid-run; the inject POST
      # is what proves the seam. (End-of-run cleanup will additionally DELETE.)
      commands = [%NetworkLatency{latency_ms: 100, jitter_ms: 0, duration_ms: 600_000}]

      adapter_config = %{
        toxiproxy: %{proxy_name: "engine", api_url: Fixture.base_url(fixture)}
      }

      assert {:ok, result} =
               Executor.run(commands, Model, SeamAdapter, adapter_config: adapter_config)

      # The injected event went through the LIVE path, not simulated.
      injected =
        Enum.find_value(result.event_log, fn entry ->
          case entry.event do
            %NetworkLatencyInjected{} = ev -> ev
            _ -> nil
          end
        end)

      assert injected, "no NetworkLatencyInjected event in the run"
      assert injected.simulated == false

      # A real POST reached the proxy through the engine.
      posts = fixture |> Fixture.requests() |> Enum.filter(&(&1.method == "POST"))
      assert [%{path: "/proxies/engine/toxics"} | _] = posts
    end
  end
end
