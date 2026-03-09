defmodule Rocket.Acceptor do
  @moduledoc """
  Accept loop process. Calls `:socket.accept/1` in a tight loop,
  hands off each connection to a new `Rocket.Connection` process.
  """
  require Logger

  def start_link(opts) do
    listen_socket = Keyword.fetch!(opts, :listen_socket)
    handler = Keyword.fetch!(opts, :handler)
    id = Keyword.fetch!(opts, :id)

    pid =
      spawn_link(fn ->
        Process.flag(:trap_exit, false)
        accept_loop(listen_socket, handler, id)
      end)

    {:ok, pid}
  end

  defp accept_loop(listen_socket, handler, id) do
    case :socket.accept(listen_socket) do
      {:ok, client_socket} ->
        :socket.setopt(client_socket, {:tcp, :nodelay}, true)

        # Spawn connection process — it will block until we send :ready
        pid = Rocket.Connection.start(client_socket, handler)

        # Transfer ownership then signal the connection to start reading
        :socket.setopt(client_socket, {:otp, :controlling_process}, pid)
        send(pid, :ready)

        accept_loop(listen_socket, handler, id)

      {:error, :closed} ->
        Logger.debug("Acceptor #{id}: listen socket closed, shutting down")
        :ok

      {:error, reason} ->
        Logger.warning("Acceptor #{id}: accept failed: #{inspect(reason)}")
        Process.sleep(1)
        accept_loop(listen_socket, handler, id)
    end
  end
end
