defmodule Rocket.Connection do
  @moduledoc """
  Per-connection process. Owns one client socket for its lifetime.

  Uses the Rocket.HTTP NIF (picohttpparser) for HTTP/1.1 request parsing.
  Builds a `Rocket.Request` struct and dispatches to the router.

  Supports:
  - Keep-alive (HTTP/1.1 default, HTTP/1.0 opt-in)
  - Content-Length body reading across multiple recv calls
  - Pipelining (leftover bytes fed back to parser)
  - Expect: 100-continue
  - Connection: close
  - Max body size enforcement (413)
  - Connection backpressure via shared counter
  """
  require Logger

  @idle_timeout_ms 60_000
  @read_timeout_ms 10_000
  @max_header_size 8192

  def start(socket, config) do
    spawn(fn -> init(socket, config) end)
  end

  defp init(socket, config) do
    receive do
      :ready -> :ok
    after
      5_000 ->
        Logger.warning("Connection: never received :ready handoff, closing")
        :socket.close(socket)
        exit(:normal)
    end

    # Track this connection
    :counters.add(config.conn_counter, 1, 1)

    try do
      recv_loop(socket, config, <<>>)
    after
      # Always decrement on exit
      :counters.add(config.conn_counter, 1, -1)
      :socket.close(socket)
    end
  end

  # Main recv loop — waits for data, accumulates into buffer, attempts parse.
  # `buffer` may contain leftover bytes from a previous pipelined request.
  defp recv_loop(socket, config, buffer) do
    # If buffer already has data (pipelining), try parsing immediately
    if byte_size(buffer) > 0 do
      handle_data(socket, config, buffer)
    else
      case :socket.recv(socket, 0, @idle_timeout_ms) do
        {:ok, data} ->
          handle_data(socket, config, data)

        {:error, :timeout} ->
          :ok

        {:error, :closed} ->
          :ok

        {:error, reason} ->
          Logger.debug("Connection recv error: #{inspect(reason)}")
          :ok
      end
    end
  end

  defp handle_data(socket, config, buffer) do
    case Rocket.HTTP.parse_request(buffer) do
      {:ok, {method, path, query_string, headers, body_offset, minor_version}} ->
        # Data after headers that's already in the buffer
        after_headers = binary_part(buffer, body_offset, byte_size(buffer) - body_offset)

        # Determine content length
        content_length = get_content_length(headers)

        # Enforce max body size
        if content_length > config.max_body do
          Rocket.Response.send_resp(%{socket: socket}, 413, "Content Too Large")
          # Don't keep-alive after rejection — client may still be sending
          :ok
        else
          # Handle Expect: 100-continue
          if has_expect_continue(headers) do
            :socket.send(socket, "HTTP/1.1 100 Continue\r\n\r\n")
          end

          # Read full body
          {body, rest} = read_body(socket, after_headers, content_length)

          # Build request
          req = Rocket.Request.build(method, path, query_string, headers, body, socket)
          dispatch(req, config.handler)

          # Determine keep-alive
          if keep_alive?(headers, minor_version) do
            recv_loop(socket, config, rest)
          else
            :ok
          end
        end

      :incomplete ->
        if byte_size(buffer) > @max_header_size do
          Rocket.Response.send_resp(%{socket: socket}, 431, "Request Header Fields Too Large")
          :ok
        else
          # Need more data to complete headers
          case :socket.recv(socket, 0, @read_timeout_ms) do
            {:ok, data} ->
              handle_data(socket, config, <<buffer::binary, data::binary>>)

            {:error, _} ->
              :ok
          end
        end

      :error ->
        Rocket.Response.send_resp(%{socket: socket}, 400, "Bad Request")
        :ok
    end
  end

  # Read the full body based on Content-Length.
  # Returns {body, leftover} where leftover is any bytes after the body
  # (pipelined next request).
  defp read_body(_socket, buffer, 0) do
    # No body expected — all of buffer is leftover (pipelining)
    {<<>>, buffer}
  end

  defp read_body(_socket, buffer, content_length)
       when byte_size(buffer) >= content_length do
    # We already have the full body in the buffer
    body = binary_part(buffer, 0, content_length)
    rest = binary_part(buffer, content_length, byte_size(buffer) - content_length)
    {body, rest}
  end

  defp read_body(socket, buffer, content_length) do
    # Need to read more data from the socket
    remaining = content_length - byte_size(buffer)
    read_body_loop(socket, buffer, remaining)
  end

  defp read_body_loop(_socket, buffer, 0) do
    {buffer, <<>>}
  end

  defp read_body_loop(socket, buffer, remaining) do
    case :socket.recv(socket, 0, @read_timeout_ms) do
      {:ok, data} ->
        buffer = <<buffer::binary, data::binary>>
        new_remaining = remaining - byte_size(data)

        if new_remaining <= 0 do
          # Got everything (and maybe more — pipelining)
          if new_remaining < 0 do
            body = binary_part(buffer, 0, byte_size(buffer) + new_remaining)
            rest = binary_part(buffer, byte_size(buffer) + new_remaining, -new_remaining)
            {body, rest}
          else
            {buffer, <<>>}
          end
        else
          read_body_loop(socket, buffer, new_remaining)
        end

      {:error, _} ->
        # Return what we have
        {buffer, <<>>}
    end
  end

  # Extract Content-Length from headers. Returns 0 if not present.
  defp get_content_length(headers) do
    case List.keyfind(headers, "Content-Length", 0) || List.keyfind(headers, "content-length", 0) do
      {_, val} ->
        case Integer.parse(val) do
          {n, _} when n >= 0 -> n
          _ -> 0
        end

      nil ->
        0
    end
  end

  # Check if Expect: 100-continue is present
  defp has_expect_continue(headers) do
    case List.keyfind(headers, "Expect", 0) || List.keyfind(headers, "expect", 0) do
      {_, val} -> String.downcase(val) == "100-continue"
      nil -> false
    end
  end

  # Determine if the connection should be kept alive.
  # HTTP/1.1: keep-alive by default unless Connection: close
  # HTTP/1.0: close by default unless Connection: keep-alive
  defp keep_alive?(headers, minor_version) do
    conn_header =
      case List.keyfind(headers, "Connection", 0) || List.keyfind(headers, "connection", 0) do
        {_, val} -> String.downcase(val)
        nil -> nil
      end

    case minor_version do
      1 -> conn_header != "close"
      0 -> conn_header == "keep-alive"
      _ -> false
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
