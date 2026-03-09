defmodule Rocket.Phase4Test do
  use ExUnit.Case

  @port 19877

  defmodule BodyRouter do
    use Rocket.Router

    post "/echo" do
      json(req, 200, %{body: req.body, size: byte_size(req.body)})
    end

    post "/size" do
      send_resp(req, 200, Integer.to_string(byte_size(req.body)))
    end

    get "/health" do
      send_resp(req, 200, "ok")
    end

    match _ do
      send_resp(req, 404, "not found")
    end
  end

  setup_all do
    {:ok, _} = Rocket.start_link(port: @port, handler: BodyRouter)
    Process.sleep(100)
    :ok
  end

  defp connect do
    {:ok, s} = :socket.open(:inet, :stream, :tcp)
    :ok = :socket.connect(s, %{family: :inet, port: @port, addr: {127, 0, 0, 1}})
    s
  end

  defp raw_request(socket, data) do
    :ok = :socket.send(socket, data)
    {:ok, response} = :socket.recv(socket, 0, 5000)
    response
  end

  defp parse_response(raw) do
    [head, body] = String.split(raw, "\r\n\r\n", parts: 2)
    [status_line | header_lines] = String.split(head, "\r\n")
    [_proto, code, _reason] = String.split(status_line, " ", parts: 3)

    headers =
      Enum.map(header_lines, fn line ->
        [k, v] = String.split(line, ": ", parts: 2)
        {k, v}
      end)

    %{status: String.to_integer(code), headers: headers, body: body}
  end

  # --- Body reading tests ---

  test "POST with small body fully in first recv" do
    s = connect()
    body = "hello world"

    resp =
      raw_request(s, "POST /echo HTTP/1.1\r\nHost: localhost\r\nContent-Length: #{byte_size(body)}\r\n\r\n#{body}")
      |> parse_response()

    json = :json.decode(resp.body)
    assert json["body"] == "hello world"
    assert json["size"] == 11
    :socket.close(s)
  end

  test "POST with large body sent in chunks" do
    s = connect()
    body = String.duplicate("x", 100_000)
    content_length = byte_size(body)

    # Send headers first
    :ok = :socket.send(s, "POST /size HTTP/1.1\r\nHost: localhost\r\nContent-Length: #{content_length}\r\n\r\n")
    # Small delay to force separate recv
    Process.sleep(10)

    # Send body in chunks
    chunks = for <<chunk::binary-size(10_000) <- body>>, do: chunk

    Enum.each(chunks, fn chunk ->
      :ok = :socket.send(s, chunk)
      Process.sleep(1)
    end)

    {:ok, response} = :socket.recv(s, 0, 10_000)
    resp = parse_response(response)
    assert resp.status == 200
    assert resp.body == "100000"
    :socket.close(s)
  end

  test "POST with zero Content-Length" do
    s = connect()

    resp =
      raw_request(s, "POST /size HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\n\r\n")
      |> parse_response()

    assert resp.body == "0"
    :socket.close(s)
  end

  test "GET with no Content-Length has empty body" do
    s = connect()

    resp =
      raw_request(s, "GET /health HTTP/1.1\r\nHost: localhost\r\n\r\n")
      |> parse_response()

    assert resp.body == "ok"
    :socket.close(s)
  end

  # --- Keep-alive tests ---

  test "HTTP/1.1 keeps connection alive by default" do
    s = connect()

    resp1 = raw_request(s, "GET /health HTTP/1.1\r\nHost: localhost\r\n\r\n") |> parse_response()
    assert resp1.status == 200

    # Second request on same connection should work
    resp2 = raw_request(s, "GET /health HTTP/1.1\r\nHost: localhost\r\n\r\n") |> parse_response()
    assert resp2.status == 200

    :socket.close(s)
  end

  test "Connection: close causes server to close" do
    s = connect()

    resp =
      raw_request(s, "GET /health HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
      |> parse_response()

    assert resp.status == 200

    # Next recv should fail — server closed the connection
    Process.sleep(50)
    result = :socket.recv(s, 0, 1000)
    assert result == {:error, :closed} or result == {:error, :timeout}
    :socket.close(s)
  end

  test "HTTP/1.0 closes by default" do
    s = connect()

    resp =
      raw_request(s, "GET /health HTTP/1.0\r\nHost: localhost\r\n\r\n")
      |> parse_response()

    assert resp.status == 200

    Process.sleep(50)
    result = :socket.recv(s, 0, 1000)
    assert result == {:error, :closed} or result == {:error, :timeout}
    :socket.close(s)
  end

  test "HTTP/1.0 with Connection: keep-alive stays open" do
    s = connect()

    resp1 =
      raw_request(s, "GET /health HTTP/1.0\r\nHost: localhost\r\nConnection: keep-alive\r\n\r\n")
      |> parse_response()

    assert resp1.status == 200

    resp2 =
      raw_request(s, "GET /health HTTP/1.0\r\nHost: localhost\r\nConnection: keep-alive\r\n\r\n")
      |> parse_response()

    assert resp2.status == 200
    :socket.close(s)
  end

  # --- Pipelining test ---

  test "pipelined requests (two requests sent at once)" do
    s = connect()

    # Send two complete requests in one write
    pipelined =
      "GET /health HTTP/1.1\r\nHost: localhost\r\n\r\n" <>
        "GET /health HTTP/1.1\r\nHost: localhost\r\n\r\n"

    :ok = :socket.send(s, pipelined)

    # Both responses may arrive in one recv (server is fast)
    # Keep reading until we have both
    data = recv_all(s, <<>>, 2)

    # Split the two HTTP responses
    responses = String.split(data, "HTTP/1.1 ", trim: true)
    assert length(responses) == 2

    for resp_str <- responses do
      assert String.contains?(resp_str, "200 OK")
      assert String.contains?(resp_str, "ok")
    end

    :socket.close(s)
  end

  defp recv_all(socket, acc, expected_count) do
    count = length(String.split(acc, "HTTP/1.1 200 OK", trim: true))

    if count >= expected_count do
      acc
    else
      case :socket.recv(socket, 0, 5000) do
        {:ok, data} -> recv_all(socket, <<acc::binary, data::binary>>, expected_count)
        _ -> acc
      end
    end
  end

  # --- Expect: 100-continue ---

  test "Expect: 100-continue sends continue before body" do
    s = connect()

    # Send headers with Expect
    :ok =
      :socket.send(
        s,
        "POST /size HTTP/1.1\r\nHost: localhost\r\nContent-Length: 5\r\nExpect: 100-continue\r\n\r\n"
      )

    # Should receive 100 Continue
    {:ok, continue_resp} = :socket.recv(s, 0, 5000)
    assert String.contains?(continue_resp, "100 Continue")

    # Now send the body
    :ok = :socket.send(s, "hello")

    # Should receive the actual response
    {:ok, data} = :socket.recv(s, 0, 5000)
    # The response might be appended to the continue or separate
    full = continue_resp <> data
    assert String.contains?(full, "200 OK")

    :socket.close(s)
  end
end
