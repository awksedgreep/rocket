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

  defp json_request(socket, data) do
    resp = request(socket, data) |> parse_response()
    %{resp | body: :json.decode(resp.body)}
  end

  test "GET request returns parsed details" do
    s = connect()
    resp = json_request(s, "GET /hello HTTP/1.1\r\nHost: localhost\r\n\r\n")
    assert resp.status == 200
    assert resp.body["method"] == "get"
    assert resp.body["path"] == "/hello"
    :socket.close(s)
  end

  test "GET with query string" do
    s = connect()
    resp = json_request(s, "GET /search?q=test&page=1 HTTP/1.1\r\nHost: localhost\r\n\r\n")
    assert resp.body["path"] == "/search"
    assert resp.body["query_string"] == "q=test&page=1"
    :socket.close(s)
  end

  test "POST with body" do
    s = connect()
    body = "hello world"

    resp =
      json_request(
        s,
        "POST /data HTTP/1.1\r\nHost: localhost\r\nContent-Length: #{byte_size(body)}\r\n\r\n#{body}"
      )

    assert resp.body["method"] == "post"
    assert resp.body["path"] == "/data"
    assert resp.body["body"] == "hello world"
    :socket.close(s)
  end

  test "headers are parsed" do
    s = connect()
    resp = json_request(s, "GET / HTTP/1.1\r\nHost: localhost\r\nX-Custom: foobar\r\n\r\n")
    assert resp.body["headers"]["Host"] == "localhost"
    assert resp.body["headers"]["X-Custom"] == "foobar"
    :socket.close(s)
  end

  test "keep-alive: multiple requests on same connection" do
    s = connect()

    resp1 = json_request(s, "GET /first HTTP/1.1\r\nHost: localhost\r\n\r\n")
    assert resp1.body["path"] == "/first"

    resp2 = json_request(s, "GET /second HTTP/1.1\r\nHost: localhost\r\n\r\n")
    assert resp2.body["path"] == "/second"

    :socket.close(s)
  end

  test "concurrent connections" do
    tasks =
      for i <- 1..100 do
        Task.async(fn ->
          s = connect()
          resp = json_request(s, "GET /conn-#{i} HTTP/1.1\r\nHost: localhost\r\n\r\n")
          assert resp.status == 200
          assert resp.body["path"] == "/conn-#{i}"
          :socket.close(s)
          :ok
        end)
      end

    results = Task.await_many(tasks, 10_000)
    assert Enum.all?(results, &(&1 == :ok))
  end
end
