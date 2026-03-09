# Start both Rocket and Bandit servers for external benchmarking with hey/wrk/ab.
#
# Usage:
#   MIX_ENV=bench mix run bench/servers.exs
#
# Then in another terminal:
#   hey -n 100000 -c 200 http://127.0.0.1:19080/health
#   hey -n 100000 -c 200 http://127.0.0.1:19081/health

defmodule Bench.BanditRouter do
  use Plug.Router

  plug :match
  plug :dispatch

  get "/health" do
    send_resp(conn, 200, "ok")
  end

  get "/json" do
    body = :json.encode(%{status: "healthy", ts: System.os_time(:second)})

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, body)
  end

  get "/query" do
    conn = Plug.Conn.fetch_query_params(conn)
    body = :json.encode(conn.query_params)

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, body)
  end

  post "/data" do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    resp = :json.encode(%{size: byte_size(body)})

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, resp)
  end

  match _ do
    send_resp(conn, 404, "not found")
  end
end

defmodule Bench.RocketRouter do
  use Rocket.Router

  get "/health" do
    send_resp(req, 200, "ok")
  end

  get "/json" do
    json(req, 200, %{status: "healthy", ts: System.os_time(:second)})
  end

  get "/query" do
    {params, _req} = Rocket.Request.query_params(req)
    json(req, 200, params)
  end

  post "/data" do
    json(req, 200, %{size: byte_size(req.body)})
  end

  match _ do
    send_resp(req, 404, "not found")
  end
end

{:ok, _} = Rocket.start_link(port: 19080, handler: Bench.RocketRouter)
{:ok, _} = Bandit.start_link(plug: Bench.BanditRouter, port: 19081)

IO.puts("")
IO.puts("  Rocket  → http://127.0.0.1:19080")
IO.puts("  Bandit  → http://127.0.0.1:19081")
IO.puts("")
IO.puts("  Endpoints: /health, /json, /query?metric=cpu&host=web-1, POST /data")
IO.puts("")
IO.puts("  Example:")
IO.puts("    hey -n 100000 -c 200 http://127.0.0.1:19080/health")
IO.puts("    hey -n 100000 -c 200 http://127.0.0.1:19081/health")
IO.puts("")
IO.puts("  Press Ctrl+C to stop.")

Process.sleep(:infinity)
