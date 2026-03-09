defmodule Rocket.Connection do
  @moduledoc """
  Per-connection process. Owns one client socket for its lifetime.

  Uses the Rocket.HTTP NIF (picohttpparser) for HTTP/1.1 request parsing.
  Builds a `Rocket.Request` struct and dispatches to the router.
  Supports keep-alive connections with idle timeout.
  """
  require Logger

  @idle_timeout_ms 60_000
  @max_header_size 8192

  def start(socket, handler) do
    spawn(fn -> init(socket, handler) end)
  end

  defp init(socket, handler) do
    receive do
      :ready -> :ok
    after
      5_000 ->
        Logger.warning("Connection: never received :ready handoff, closing")
        :socket.close(socket)
        exit(:normal)
    end

    recv_loop(socket, handler, <<>>)
  end

  defp recv_loop(socket, handler, buffer) do
    case :socket.recv(socket, 0, @idle_timeout_ms) do
      {:ok, data} ->
        buffer = <<buffer::binary, data::binary>>
        handle_data(socket, handler, buffer)

      {:error, :timeout} ->
        :socket.close(socket)

      {:error, :closed} ->
        :ok

      {:error, reason} ->
        Logger.debug("Connection recv error: #{inspect(reason)}")
        :socket.close(socket)
    end
  end

  defp handle_data(socket, handler, buffer) do
    case Rocket.HTTP.parse_request(buffer) do
      {:ok, {method, path, query_string, headers, body_offset, _minor_version}} ->
        body =
          if body_offset < byte_size(buffer) do
            binary_part(buffer, body_offset, byte_size(buffer) - body_offset)
          else
            <<>>
          end

        req = Rocket.Request.build(method, path, query_string, headers, body, socket)
        dispatch(req, handler)

        # Keep-alive: loop back for next request
        recv_loop(socket, handler, <<>>)

      :incomplete ->
        if byte_size(buffer) > @max_header_size do
          Rocket.Response.send_resp(%{socket: socket}, 431, "Request Header Fields Too Large")
          :socket.close(socket)
        else
          recv_loop(socket, handler, buffer)
        end

      :error ->
        Rocket.Response.send_resp(%{socket: socket}, 400, "Bad Request")
        :socket.close(socket)
    end
  end

  defp dispatch(req, handler) do
    try do
      handler.handle(req)
    rescue
      e ->
        Logger.error("Handler crash: #{Exception.format(:error, e, __STACKTRACE__)}")
        Rocket.Response.send_resp(req, 500, "Internal Server Error")
    end
  end
end
