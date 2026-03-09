defmodule Rocket.Response do
  @moduledoc """
  Response helpers for Rocket handlers.
  """

  @doc """
  Send a response with no body.
  """
  def send_resp(%{socket: socket}, status) do
    response = [status_line(status), "content-length: 0\r\nconnection: keep-alive\r\n\r\n"]
    :socket.send(socket, response)
  end

  @doc """
  Send a response with a binary body.
  """
  def send_resp(%{socket: socket}, status, body) when is_binary(body) do
    response = [
      status_line(status),
      "content-length: ",
      Integer.to_string(byte_size(body)),
      "\r\nconnection: keep-alive\r\n\r\n",
      body
    ]

    :socket.send(socket, response)
  end

  @doc """
  Send a JSON response. Encodes the term with `:json.encode/1`.
  """
  def json(%{socket: socket}, status, term) do
    body = IO.iodata_to_binary(:json.encode(term))

    response = [
      status_line(status),
      "content-type: application/json\r\ncontent-length: ",
      Integer.to_string(byte_size(body)),
      "\r\nconnection: keep-alive\r\n\r\n",
      body
    ]

    :socket.send(socket, response)
  end

  @doc """
  Send a response with custom headers and iodata body.
  Headers should be a list of `{name, value}` tuples.
  """
  def send_iodata(%{socket: socket}, status, headers, iodata) do
    body = IO.iodata_to_binary(iodata)

    header_lines =
      Enum.map(headers, fn {name, value} ->
        [name, ": ", value, "\r\n"]
      end)

    response = [
      status_line(status),
      "content-length: ",
      Integer.to_string(byte_size(body)),
      "\r\n",
      header_lines,
      "connection: keep-alive\r\n\r\n",
      body
    ]

    :socket.send(socket, response)
  end

  # Pre-built status lines as compile-time binaries
  defp status_line(200), do: "HTTP/1.1 200 OK\r\n"
  defp status_line(201), do: "HTTP/1.1 201 Created\r\n"
  defp status_line(204), do: "HTTP/1.1 204 No Content\r\n"
  defp status_line(301), do: "HTTP/1.1 301 Moved Permanently\r\n"
  defp status_line(302), do: "HTTP/1.1 302 Found\r\n"
  defp status_line(304), do: "HTTP/1.1 304 Not Modified\r\n"
  defp status_line(400), do: "HTTP/1.1 400 Bad Request\r\n"
  defp status_line(401), do: "HTTP/1.1 401 Unauthorized\r\n"
  defp status_line(403), do: "HTTP/1.1 403 Forbidden\r\n"
  defp status_line(404), do: "HTTP/1.1 404 Not Found\r\n"
  defp status_line(405), do: "HTTP/1.1 405 Method Not Allowed\r\n"
  defp status_line(413), do: "HTTP/1.1 413 Content Too Large\r\n"
  defp status_line(422), do: "HTTP/1.1 422 Unprocessable Entity\r\n"
  defp status_line(429), do: "HTTP/1.1 429 Too Many Requests\r\n"
  defp status_line(431), do: "HTTP/1.1 431 Request Header Fields Too Large\r\n"
  defp status_line(500), do: "HTTP/1.1 500 Internal Server Error\r\n"
  defp status_line(503), do: "HTTP/1.1 503 Service Unavailable\r\n"
  defp status_line(code), do: "HTTP/1.1 #{code}\r\n"
end
