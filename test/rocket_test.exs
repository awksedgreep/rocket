defmodule RocketTest do
  use ExUnit.Case

  @port 19876

  setup_all do
    {:ok, _} = Rocket.start_link(port: @port, handler: Rocket.EchoHandler)
    Process.sleep(100)
    :ok
  end

  defp connect do
    {:ok, s} = :socket.open(:inet, :stream, :tcp)
    :ok = :socket.connect(s, %{family: :inet, port: @port, addr: {127, 0, 0, 1}})
    s
  end

  defp request(socket, data) do
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

  test "GET request" do
    s = connect()
    resp = request(s, "GET /hello HTTP/1.1\r\nHost: localhost\r\n\r\n") |> parse_response()
    assert resp.status == 200
    assert resp.body == "get /hello\n"
    :socket.close(s)
  end

  test "POST request" do
    s = connect()

    resp =
      request(s, "POST /data HTTP/1.1\r\nHost: localhost\r\nContent-Length: 4\r\n\r\ntest")
      |> parse_response()

    assert resp.status == 200
    assert resp.body == "post /data\n"
    :socket.close(s)
  end

  test "keep-alive: multiple requests on same connection" do
    s = connect()

    resp1 = request(s, "GET /first HTTP/1.1\r\nHost: localhost\r\n\r\n") |> parse_response()
    assert resp1.status == 200
    assert resp1.body == "get /first\n"

    resp2 = request(s, "GET /second HTTP/1.1\r\nHost: localhost\r\n\r\n") |> parse_response()
    assert resp2.status == 200
    assert resp2.body == "get /second\n"

    :socket.close(s)
  end

  test "returns connection: keep-alive header" do
    s = connect()
    resp = request(s, "GET /test HTTP/1.1\r\nHost: localhost\r\n\r\n") |> parse_response()
    assert {"connection", "keep-alive"} in resp.headers
    :socket.close(s)
  end

  test "returns correct content-length" do
    s = connect()
    resp = request(s, "GET /hi HTTP/1.1\r\nHost: localhost\r\n\r\n") |> parse_response()
    assert {"content-length", "8"} in resp.headers
    assert resp.body == "get /hi\n"
    :socket.close(s)
  end

  test "concurrent connections" do
    tasks =
      for i <- 1..50 do
        Task.async(fn ->
          s = connect()

          resp =
            request(s, "GET /conn-#{i} HTTP/1.1\r\nHost: localhost\r\n\r\n") |> parse_response()

          assert resp.status == 200
          assert resp.body == "get /conn-#{i}\n"
          :socket.close(s)
          :ok
        end)
      end

    results = Task.await_many(tasks, 10_000)
    assert Enum.all?(results, &(&1 == :ok))
  end
end
