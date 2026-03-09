defmodule Rocket.Connection do
  @moduledoc """
  Per-connection process. Owns one client socket for its lifetime.

  Phase 1: Simple HTTP echo server — reads data, parses a minimal HTTP
  request (enough to find the end of headers), and sends back a response.

  Later phases will integrate the NIF parser and router.
  """
  require Logger

  @idle_timeout_ms 60_000

  def start(socket, handler) do
    spawn(fn -> init(socket, handler) end)
  end

  defp init(socket, handler) do
    # Wait for the acceptor to transfer socket ownership
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
    case :binary.match(buffer, <<"\r\n\r\n">>) do
      {pos, 4} ->
        header_data = :binary.part(buffer, 0, pos)
        body_start = pos + 4
        rest = :binary.part(buffer, body_start, byte_size(buffer) - body_start)

        case parse_request_line(header_data) do
          {:ok, method, path} ->
            req = %{
              method: method,
              path: path,
              socket: socket,
              body: rest
            }

            dispatch(req, handler)

            # Keep-alive: loop back for next request
            recv_loop(socket, handler, <<>>)

          :error ->
            send_response(socket, 400, "Bad Request")
            :socket.close(socket)
        end

      :nomatch ->
        if byte_size(buffer) > 8192 do
          send_response(socket, 431, "Request Header Fields Too Large")
          :socket.close(socket)
        else
          recv_loop(socket, handler, buffer)
        end
    end
  end

  defp parse_request_line(header_data) do
    case :binary.match(header_data, <<"\r\n">>) do
      {pos, 2} ->
        request_line = :binary.part(header_data, 0, pos)
        parse_method_and_path(request_line)

      :nomatch ->
        parse_method_and_path(header_data)
    end
  end

  defp parse_method_and_path(line) do
    case :binary.split(line, <<" ">>, [:global]) do
      [method, path, _version] ->
        {:ok, normalize_method(method), path}

      [method, path] ->
        {:ok, normalize_method(method), path}

      _ ->
        :error
    end
  end

  defp normalize_method(<<"GET">>), do: :get
  defp normalize_method(<<"POST">>), do: :post
  defp normalize_method(<<"PUT">>), do: :put
  defp normalize_method(<<"DELETE">>), do: :delete
  defp normalize_method(<<"HEAD">>), do: :head
  defp normalize_method(<<"OPTIONS">>), do: :options
  defp normalize_method(<<"PATCH">>), do: :patch
  defp normalize_method(other), do: String.downcase(other) |> String.to_atom()

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
