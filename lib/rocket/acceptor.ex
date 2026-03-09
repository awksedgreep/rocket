defmodule Rocket.Acceptor do
  @moduledoc """
  Accept loop process. Calls `:socket.accept/1` in a tight loop,
  hands off each connection to a new `Rocket.Connection` process.

  Enforces max_connections via a shared `:counters` ref — if the limit
  is reached, the accepted socket is immediately closed with a 503.
  """
  require Logger

  def start_link(opts) do
    listen_socket = Keyword.fetch!(opts, :listen_socket)
    config = Keyword.fetch!(opts, :config)
    id = Keyword.fetch!(opts, :id)

    pid =
      spawn_link(fn ->
        Process.flag(:trap_exit, false)
        accept_loop(listen_socket, config, id)
      end)

    {:ok, pid}
  end

  defp accept_loop(listen_socket, config, id) do
    case :socket.accept(listen_socket) do
      {:ok, client_socket} ->
        active = :counters.get(config.conn_counter, 1)

        if active >= config.max_connections do
          # Over limit — reject immediately
          :socket.send(client_socket, "HTTP/1.1 503 Service Unavailable\r\nConnection: close\r\nContent-Length: 19\r\n\r\nService Unavailable")
          :socket.close(client_socket)
        else
          :socket.setopt(client_socket, {:tcp, :nodelay}, true)

          # Spawn connection process — it will block until we send :ready
          pid = Rocket.Connection.start(client_socket, config)

          # Transfer ownership then signal the connection to start reading
          :socket.setopt(client_socket, {:otp, :controlling_process}, pid)
          send(pid, :ready)
        end

        accept_loop(listen_socket, config, id)

      {:error, :closed} ->
        Logger.debug("Acceptor #{id}: listen socket closed, shutting down")
        :ok

      {:error, reason} ->
        Logger.warning("Acceptor #{id}: accept failed: #{inspect(reason)}")
        Process.sleep(1)
        accept_loop(listen_socket, config, id)
    end
  end
end
