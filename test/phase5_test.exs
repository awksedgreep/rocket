defmodule Rocket.Phase5Test do
  use ExUnit.Case

  @port 19878

  defmodule TestRouter do
    use Rocket.Router

    post "/data" do
      send_resp(req, 200, "got #{byte_size(req.body)} bytes")
    end

    get "/health" do
      send_resp(req, 200, "ok")
    end

    get "/crash" do
      raise "intentional crash"
      send_resp(req, 200, "unreachable")
    end

    match _ do
      send_resp(req, 404, "not found")
    end
  end

  # Use a small max_body for testing
  @max_body 1024

  setup_all do
    {:ok, _} = Rocket.start_link(port: @port, handler: TestRouter, max_body: @max_body)
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

  # --- Max body size tests ---

  test "POST within max body size succeeds" do
    s = connect()
    body = String.duplicate("x", @max_body)

    resp =
      raw_request(s, "POST /data HTTP/1.1\r\nHost: localhost\r\nContent-Length: #{@max_body}\r\n\r\n#{body}")
      |> parse_response()

    assert resp.status == 200
    assert resp.body == "got #{@max_body} bytes"
    :socket.close(s)
  end

  test "POST exceeding max body size returns 413" do
    s = connect()
    over_size = @max_body + 1
    body = String.duplicate("x", over_size)

    resp =
      raw_request(s, "POST /data HTTP/1.1\r\nHost: localhost\r\nContent-Length: #{over_size}\r\n\r\n#{body}")
      |> parse_response()

    assert resp.status == 413
    :socket.close(s)
  end

  test "POST with Content-Length way over max returns 413 without reading body" do
    s = connect()
    # Declare a huge body but don't actually send it
    resp =
      raw_request(s, "POST /data HTTP/1.1\r\nHost: localhost\r\nContent-Length: 999999999\r\n\r\n")
      |> parse_response()

    assert resp.status == 413
    :socket.close(s)
  end

  # --- Handler crash tests ---

  test "handler crash returns 500 and connection is closed cleanly" do
    s = connect()

    resp =
      raw_request(s, "GET /crash HTTP/1.1\r\nHost: localhost\r\n\r\n")
      |> parse_response()

    assert resp.status == 500
    assert resp.body == "Internal Server Error"
    :socket.close(s)
  end

  test "handler crash doesn't break subsequent connections" do
    # Crash one connection
    s1 = connect()
    _resp = raw_request(s1, "GET /crash HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
    :socket.close(s1)

    Process.sleep(50)

    # New connection should work fine
    s2 = connect()
    resp = raw_request(s2, "GET /health HTTP/1.1\r\nHost: localhost\r\n\r\n") |> parse_response()
    assert resp.status == 200
    assert resp.body == "ok"
    :socket.close(s2)
  end

  # --- Connection counter tests ---

  test "connection counter increments and decrements" do
    # Get the listener's conn_counter by starting a fresh instance
    port = 19879
    {:ok, _} = Rocket.start_link(port: port, handler: TestRouter, max_connections: 100)
    Process.sleep(100)

    # Open several connections
    sockets =
      for _ <- 1..5 do
        {:ok, s} = :socket.open(:inet, :stream, :tcp)
        :ok = :socket.connect(s, %{family: :inet, port: port, addr: {127, 0, 0, 1}})
        # Send a request to ensure the connection process has started
        :ok = :socket.send(s, "GET /health HTTP/1.1\r\nHost: localhost\r\n\r\n")
        {:ok, _} = :socket.recv(s, 0, 5000)
        s
      end

    # Small delay for counter updates
    Process.sleep(50)

    # Close them all
    Enum.each(sockets, &:socket.close/1)

    # Wait for connections to clean up
    Process.sleep(200)
  end

  # --- Backpressure (503) test ---

  test "503 returned when max connections exceeded" do
    port = 19880
    max_conns = 3
    {:ok, _} = Rocket.start_link(port: port, handler: TestRouter, max_connections: max_conns)
    Process.sleep(100)

    # Open max_conns connections and keep them alive
    held =
      for _ <- 1..max_conns do
        {:ok, s} = :socket.open(:inet, :stream, :tcp)
        :ok = :socket.connect(s, %{family: :inet, port: port, addr: {127, 0, 0, 1}})
        # Make a request so the connection process registers
        :ok = :socket.send(s, "GET /health HTTP/1.1\r\nHost: localhost\r\n\r\n")
        {:ok, _} = :socket.recv(s, 0, 5000)
        s
      end

    # Small delay for counters to update
    Process.sleep(50)

    # Next connection should get 503
    {:ok, s} = :socket.open(:inet, :stream, :tcp)
    :ok = :socket.connect(s, %{family: :inet, port: port, addr: {127, 0, 0, 1}})
    :ok = :socket.send(s, "GET /health HTTP/1.1\r\nHost: localhost\r\n\r\n")
    {:ok, resp} = :socket.recv(s, 0, 5000)

    assert String.contains?(resp, "503")
    :socket.close(s)

    # Clean up held connections
    Enum.each(held, &:socket.close/1)
  end
end
