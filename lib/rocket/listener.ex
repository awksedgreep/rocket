defmodule Rocket.Listener do
  @moduledoc """
  Opens a TCP listening socket and spawns an acceptor pool.

  Uses OTP 28 `:socket` module for optimal performance with
  persistent poll-set registration.
  """
  use GenServer
  require Logger

  @default_port 8080
  @default_backlog 1024

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    port = Keyword.get(opts, :port, @default_port)
    backlog = Keyword.get(opts, :backlog, @default_backlog)
    handler = Keyword.fetch!(opts, :handler)
    num_acceptors = Keyword.get(opts, :num_acceptors, System.schedulers_online())

    case open_listener(port, backlog) do
      {:ok, listen_socket} ->
        Logger.info("Rocket listening on port #{port} with #{num_acceptors} acceptors")

        acceptors =
          for i <- 1..num_acceptors do
            {:ok, pid} =
              Rocket.Acceptor.start_link(
                listen_socket: listen_socket,
                handler: handler,
                id: i
              )

            pid
          end

        state = %{
          listen_socket: listen_socket,
          port: port,
          handler: handler,
          acceptors: acceptors
        }

        {:ok, state}

      {:error, reason} ->
        {:stop, {:listen_failed, reason}}
    end
  end

  @impl true
  def terminate(_reason, state) do
    :socket.close(state.listen_socket)
    :ok
  end

  defp open_listener(port, backlog) do
    with {:ok, socket} <- :socket.open(:inet, :stream, :tcp),
         :ok <- :socket.setopt(socket, {:socket, :reuseaddr}, true),
         :ok <- set_reuseport(socket),
         :ok <- :socket.setopt(socket, {:tcp, :nodelay}, true),
         :ok <- :socket.bind(socket, %{family: :inet, port: port, addr: {0, 0, 0, 0}}),
         :ok <- :socket.listen(socket, backlog) do
      {:ok, socket}
    end
  end

  defp set_reuseport(socket) do
    case :socket.setopt(socket, {:socket, :reuseport}, true) do
      :ok -> :ok
      # SO_REUSEPORT not available on all platforms — non-fatal
      {:error, _} -> :ok
    end
  end
end
