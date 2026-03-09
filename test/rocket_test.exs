defmodule RocketTest do
  use ExUnit.Case

  @port 19876

  # Test router with various route types
  defmodule TestRouter do
    use Rocket.Router

    get "/health" do
      send_resp(req, 200, "ok")
    end

    get "/json" do
      json(req, 200, %{status: "healthy"})
    end

    get "/echo/:name" do
      json(req, 200, %{name: req.path_params["name"]})
    end

    get "/api/v1/label/:name/values" do
      json(req, 200, %{label: req.path_params["name"], path: req.path})
    end

    post "/data" do
      json(req, 200, %{method: "post", body: req.body, path: req.path})
    end

    get "/query" do
      {params, _req} = Rocket.Request.query_params(req)
      json(req, 200, params)
    end

    get "/headers" do
      host = Rocket.Request.get_header(req, "Host")
      custom = Rocket.Request.get_header(req, "X-Custom")
      json(req, 200, %{host: host, custom: custom})
    end

    delete "/resource/:id" do
      json(req, 200, %{deleted: req.path_params["id"]})
    end

    match _ do
      send_resp(req, 404, "not found")
    end
  end

  setup_all do
    {:ok, _} = Rocket.start_link(port: @port, handler: TestRouter)
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

  defp get(path, extra_headers \\ "") do
    s = connect()
    resp = request(s, "GET #{path} HTTP/1.1\r\nHost: localhost\r\n#{extra_headers}\r\n") |> parse_response()
    :socket.close(s)
    resp
  end

  defp get_json(path, extra_headers \\ "") do
    resp = get(path, extra_headers)
    %{resp | body: :json.decode(resp.body)}
  end

  # --- Route tests ---

  test "GET /health returns 200 with text body" do
    resp = get("/health")
    assert resp.status == 200
    assert resp.body == "ok"
  end

  test "GET /json returns JSON with content-type" do
    resp = get("/json")
    assert resp.status == 200
    assert {"content-type", "application/json"} in resp.headers
    assert :json.decode(resp.body) == %{"status" => "healthy"}
  end

  test "path params: GET /echo/:name" do
    resp = get_json("/echo/world")
    assert resp.body["name"] == "world"
  end

  test "path params: nested /api/v1/label/:name/values" do
    resp = get_json("/api/v1/label/host/values")
    assert resp.body["label"] == "host"
    assert resp.body["path"] == "/api/v1/label/host/values"
  end

  test "POST with body" do
    s = connect()
    body = "hello world"

    resp =
      request(s, "POST /data HTTP/1.1\r\nHost: localhost\r\nContent-Length: #{byte_size(body)}\r\n\r\n#{body}")
      |> parse_response()

    :socket.close(s)
    json = :json.decode(resp.body)
    assert json["method"] == "post"
    assert json["body"] == "hello world"
  end

  test "query params via NIF" do
    resp = get_json("/query?metric=cpu&host=web-1&start=1700000000")
    assert resp.body["metric"] == "cpu"
    assert resp.body["host"] == "web-1"
    assert resp.body["start"] == "1700000000"
  end

  test "headers accessible" do
    resp = get_json("/headers", "X-Custom: foobar\r\n")
    assert resp.body["host"] == "localhost"
    assert resp.body["custom"] == "foobar"
  end

  test "DELETE with path param" do
    s = connect()
    resp = request(s, "DELETE /resource/42 HTTP/1.1\r\nHost: localhost\r\n\r\n") |> parse_response()
    :socket.close(s)
    assert resp.status == 200
    assert :json.decode(resp.body)["deleted"] == "42"
  end

  test "404 for unknown route" do
    resp = get("/nonexistent/path")
    assert resp.status == 404
    assert resp.body == "not found"
  end

  test "keep-alive: multiple requests on same connection" do
    s = connect()

    resp1 = request(s, "GET /health HTTP/1.1\r\nHost: localhost\r\n\r\n") |> parse_response()
    assert resp1.status == 200
    assert resp1.body == "ok"

    resp2 = request(s, "GET /echo/test HTTP/1.1\r\nHost: localhost\r\n\r\n") |> parse_response()
    assert resp2.status == 200
    assert :json.decode(resp2.body)["name"] == "test"

    :socket.close(s)
  end

  test "concurrent connections" do
    tasks =
      for i <- 1..100 do
        Task.async(fn ->
          resp = get_json("/echo/conn-#{i}")
          assert resp.status == 200
          assert resp.body["name"] == "conn-#{i}"
          :ok
        end)
      end

    results = Task.await_many(tasks, 10_000)
    assert Enum.all?(results, &(&1 == :ok))
  end
end
