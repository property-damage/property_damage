defmodule Mix.Tasks.Pd.Gen.Adapter do
  @moduledoc """
  Generate a PropertyDamage adapter module.

  ## Usage

      mix pd.gen.adapter MyApp.HTTPAdapter

  ## Options

      --type TYPE    Adapter type: http, grpc, or direct (default: http)

  ## Examples

      # HTTP adapter
      mix pd.gen.adapter MyApp.HTTPAdapter

      # gRPC adapter
      mix pd.gen.adapter MyApp.GRPCAdapter --type grpc

      # Direct adapter (for in-process testing)
      mix pd.gen.adapter MyApp.DirectAdapter --type direct
  """

  use Mix.Task

  @shortdoc "Generate a PropertyDamage adapter module"

  @impl true
  def run(args) do
    {opts, argv, _} = OptionParser.parse(args, strict: [type: :string])

    case argv do
      [module_name] ->
        type = Keyword.get(opts, :type, "http")
        generate_adapter(module_name, type)

      [] ->
        Mix.shell().error("Usage: mix pd.gen.adapter MODULE_NAME [OPTIONS]")
        Mix.shell().error("Run `mix help pd.gen.adapter` for more information.")

      _ ->
        Mix.shell().error("Expected exactly one module name")
    end
  end

  defp generate_adapter(module_name, type) do
    path = module_to_path(module_name)
    dir = Path.dirname(path)

    File.mkdir_p!(dir)

    content =
      case type do
        "http" ->
          generate_http_adapter(module_name)

        "grpc" ->
          generate_grpc_adapter(module_name)

        "direct" ->
          generate_direct_adapter(module_name)

        _ ->
          Mix.shell().error("Unknown adapter type: #{type}")
          Mix.shell().error("Use 'http', 'grpc', or 'direct'")
          System.halt(1)
      end

    File.write!(path, content)

    Mix.shell().info("Generated #{path}")
    Mix.shell().info("")
    Mix.shell().info("Next steps:")
    Mix.shell().info("  1. Add command and event aliases")
    Mix.shell().info("  2. Implement execute/2 for each command")
    Mix.shell().info("  3. Update setup/1 with your connection config")
  end

  defp module_to_path(module_name) do
    module_name
    |> String.replace(".", "/")
    |> Macro.underscore()
    |> then(&"lib/#{&1}.ex")
  end

  defp generate_http_adapter(module_name) do
    """
    defmodule #{module_name} do
      @moduledoc \"\"\"
      HTTP adapter for PropertyDamage tests.

      TODO: Add description of what system this connects to.
      \"\"\"

      @behaviour PropertyDamage.Adapter

      # TODO: Add command aliases
      # alias MyApp.Commands.{CreateEntity, UpdateEntity, DeleteEntity}

      # TODO: Add event aliases
      # alias MyApp.Events.{EntityCreated, EntityUpdated, EntityDeleted, OperationFailed}

      @impl true
      def setup(opts) do
        base_url = Keyword.get(opts, :base_url, "http://localhost:4000")
        {:ok, %{base_url: base_url}}
      end

      @impl true
      def teardown(_context) do
        :ok
      end

      @impl true
      # TODO: Implement execute/2 for each command
      #
      # def execute(%CreateEntity{name: name} = _cmd, %{base_url: base_url}) do
      #   case post(base_url, "/entities", %{name: name}) do
      #     {:ok, %{status: 201, body: body}} ->
      #       {:ok, %EntityCreated{id: body["id"], name: body["name"]}}
      #
      #     {:ok, %{status: 400, body: body}} ->
      #       {:ok, %OperationFailed{reason: body["error"]}}
      #
      #     {:error, reason} ->
      #       {:error, reason}
      #   end
      # end

      def execute(command, _context) do
        raise "Not implemented: execute for \#{inspect(command.__struct__)}"
      end

      # HTTP helpers

      defp get(base_url, path) do
        case Req.get(base_url <> path) do
          {:ok, %{status: status, body: body}} -> {:ok, %{status: status, body: body}}
          {:error, error} -> {:error, Exception.message(error)}
        end
      end

      defp post(base_url, path, body) do
        case Req.post(base_url <> path, json: body) do
          {:ok, %{status: status, body: body}} -> {:ok, %{status: status, body: body}}
          {:error, error} -> {:error, Exception.message(error)}
        end
      end

      defp put(base_url, path, body) do
        case Req.put(base_url <> path, json: body) do
          {:ok, %{status: status, body: body}} -> {:ok, %{status: status, body: body}}
          {:error, error} -> {:error, Exception.message(error)}
        end
      end

      defp delete(base_url, path) do
        case Req.delete(base_url <> path) do
          {:ok, %{status: status, body: body}} -> {:ok, %{status: status, body: body}}
          {:error, error} -> {:error, Exception.message(error)}
        end
      end
    end
    """
  end

  defp generate_grpc_adapter(module_name) do
    """
    defmodule #{module_name} do
      @moduledoc \"\"\"
      gRPC adapter for PropertyDamage tests.

      TODO: Add description of what system this connects to.
      \"\"\"

      @behaviour PropertyDamage.Adapter

      # TODO: Add command aliases
      # alias MyApp.Commands.{CreateEntity, UpdateEntity}

      # TODO: Add event aliases
      # alias MyApp.Events.{EntityCreated, EntityUpdated}

      @impl true
      def setup(opts) do
        host = Keyword.get(opts, :host, "localhost")
        port = Keyword.get(opts, :port, 50051)

        case GRPC.Stub.connect("\#{host}:\#{port}") do
          {:ok, channel} ->
            {:ok, %{channel: channel}}

          {:error, reason} ->
            {:error, {:connection_failed, reason}}
        end
      end

      @impl true
      def teardown(%{channel: channel}) do
        GRPC.Stub.disconnect(channel)
        :ok
      end

      @impl true
      # TODO: Implement execute/2 for each command
      #
      # def execute(%CreateEntity{name: name}, %{channel: channel}) do
      #   request = %MyProto.CreateRequest{name: name}
      #
      #   case MyService.Stub.create(channel, request) do
      #     {:ok, response} ->
      #       {:ok, %EntityCreated{id: response.id, name: response.name}}
      #
      #     {:error, %GRPC.RPCError{status: 3}} ->  # INVALID_ARGUMENT
      #       {:ok, %OperationFailed{reason: :invalid_input}}
      #
      #     {:error, error} ->
      #       {:error, error}
      #   end
      # end

      def execute(command, _context) do
        raise "Not implemented: execute for \#{inspect(command.__struct__)}"
      end
    end
    """
  end

  defp generate_direct_adapter(module_name) do
    """
    defmodule #{module_name} do
      @moduledoc \"\"\"
      Direct adapter for PropertyDamage tests (in-process).

      This adapter calls the system under test directly without network overhead.
      Useful for fast testing during development.

      TODO: Add description of what system this connects to.
      \"\"\"

      @behaviour PropertyDamage.Adapter

      # TODO: Add command aliases
      # alias MyApp.Commands.{CreateEntity, UpdateEntity}

      # TODO: Add event aliases
      # alias MyApp.Events.{EntityCreated, EntityUpdated}

      @impl true
      def setup(opts) do
        # TODO: Start your system under test
        # {:ok, pid} = MyApp.Server.start_link(opts)
        # {:ok, %{pid: pid}}
        {:ok, %{}}
      end

      @impl true
      def teardown(_context) do
        # TODO: Stop your system under test
        # GenServer.stop(context.pid)
        :ok
      end

      @impl true
      # TODO: Implement execute/2 for each command
      #
      # def execute(%CreateEntity{name: name}, %{pid: pid}) do
      #   case GenServer.call(pid, {:create, name}) do
      #     {:ok, entity} ->
      #       {:ok, %EntityCreated{id: entity.id, name: entity.name}}
      #
      #     {:error, reason} ->
      #       {:ok, %OperationFailed{reason: reason}}
      #   end
      # end

      def execute(command, _context) do
        raise "Not implemented: execute for \#{inspect(command.__struct__)}"
      end
    end
    """
  end
end
