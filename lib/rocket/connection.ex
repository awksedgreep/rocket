defmodule Rocket.Connection do
  @moduledoc """
  Per-connection process. Owns one client socket for its lifetime.

  Uses the Rocket.HTTP NIF (picohttpparser) for HTTP/1.1 request parsing.
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
        # Extract any body data already in the buffer
        body =
          if body_offset < byte_size(buffer) do
            binary_part(buffer, body_offset, byte_size(buffer) - body_offset)
          else
            <<>>
          end

        req = %{
          method: method,
          path: path,
          query_string: query_string,
          headers: headers,
          body: body,
          socket: socket
        }

        dispatch(req, handler)

        # Keep-alive: loop back for next request
        recv_loop(socket, handler, <<>>)

      :incomplete ->
        if byte_size(buffer) > @max_header_size do
          send_response(socket, 431, "Request Header Fields Too Large")
          :socket.close(socket)
        else
          recv_loop(socket, handler, buffer)
        end

      :error ->
        send_response(socket, 400, "Bad Request")
        :socket.close(socket)
    end
  end

  defp dispatch(req, handler) do
    try do
      handler.handle(req)
    rescue
      e ->
        Logger.error("Handler crash: #{Exception.format(:error, e, __STACKTRACE__)}")
        send_response(req.socket, 500, "Internal Server Error")
    end
  end

  @doc false
  def send_response(socket, status, body) when is_binary(body) do
    status_line = status_line(status)
    content_length = Integer.to_string(byte_size(body))

    response = [
      status_line,
      "content-length: ",
      content_length,
      "\r\nconnection: keep-alive\r\n\r\n",
      body
    ]

    :socket.send(socket, response)
  end

  def send_response(socket, status) do
    response = [status_line(status), "content-length: 0\r\nconnection: keep-alive\r\n\r\n"]
    :socket.send(socket, response)
  end

  defp status_line(200), do: "HTTP/1.1 200 OK\r\n"
  defp status_line(204), do: "HTTP/1.1 204 No Content\r\n"
  defp status_line(400), do: "HTTP/1.1 400 Bad Request\r\n"
  defp status_line(404), do: "HTTP/1.1 404 Not Found\r\n"
  defp status_line(413), do: "HTTP/1.1 413 Content Too Large\r\n"
  defp status_line(431), do: "HTTP/1.1 431 Request Header Fields Too Large\r\n"
  defp status_line(500), do: "HTTP/1.1 500 Internal Server Error\r\n"
  defp status_line(503), do: "HTTP/1.1 503 Service Unavailable\r\n"
  defp status_line(code), do: "HTTP/1.1 #{code}\r\n"
end
