# Benchmark: Rocket vs Bandit+Plug
#
# Runs identical workloads against both servers and compares latency/throughput.
#
# Usage:
#   MIX_ENV=bench mix run bench/vs_bandit.exs
#   MIX_ENV=bench mix run bench/vs_bandit.exs --concurrency 200 --requests 50000

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

defmodule Bench do
  @rocket_port 19_080
  @bandit_port 19_081

  def run(opts) do
    concurrency = Keyword.get(opts, :concurrency, 100)
    requests = Keyword.get(opts, :requests, 20_000)

    IO.puts("================================================================")
    IO.puts("  Rocket vs Bandit+Plug Benchmark")
    IO.puts("================================================================")
    IO.puts("  Concurrency:    #{concurrency}")
    IO.puts("  Requests/test:  #{fmt_int(requests)}")
    IO.puts("  Rocket port:    #{@rocket_port}")
    IO.puts("  Bandit port:    #{@bandit_port}")
    IO.puts("================================================================\n")

    # Start servers
    {:ok, _} = Rocket.start_link(port: @rocket_port, handler: Bench.RocketRouter)
    {:ok, _} = Bandit.start_link(plug: Bench.BanditRouter, port: @bandit_port)

    Process.sleep(500)

    # Warmup
    IO.puts("Warming up...")
    run_test("http://127.0.0.1:#{@rocket_port}", "/health", :get, nil, 1000, 50)
    run_test("http://127.0.0.1:#{@bandit_port}", "/health", :get, nil, 1000, 50)
    IO.puts("")

    scenarios = [
      {"GET /health (text)", "/health", :get, nil},
      {"GET /json (JSON encode)", "/json", :get, nil},
      {"GET /query (parse QS)", "/query?metric=cpu&host=web-1&region=us-east", :get, nil},
      {"POST /data (1KB body)", "/data", :post, String.duplicate("x", 1024)}
    ]

    results =
      for {name, path, method, body} <- scenarios do
        IO.puts("--- #{name} ---")

        rocket_stats = run_test("http://127.0.0.1:#{@rocket_port}", path, method, body, requests, concurrency)
        bandit_stats = run_test("http://127.0.0.1:#{@bandit_port}", path, method, body, requests, concurrency)

        print_comparison(rocket_stats, bandit_stats)
        IO.puts("")

        {name, rocket_stats, bandit_stats}
      end

    # Summary
    IO.puts("================================================================")
    IO.puts("  Summary")
    IO.puts("================================================================")

    for {name, rocket, bandit} <- results do
      r_p50 = fmt_us(rocket.p50)
      b_p50 = fmt_us(bandit.p50)
      r_rps = fmt_int(rocket.rps)
      b_rps = fmt_int(bandit.rps)
      speedup = Float.round(bandit.p50 / max(rocket.p50, 1), 1)
      IO.puts("  #{String.pad_trailing(name, 30)} Rocket #{r_p50} (#{r_rps} rps)  Bandit #{b_p50} (#{b_rps} rps)  #{speedup}x")
    end

    IO.puts("================================================================")
  end

  defp run_test(base_url, path, method, body, total, concurrency) do
    ets = :ets.new(:bench, [:ordered_set, :public, {:write_concurrency, true}])
    counter = :counters.new(2, [:atomics])  # 1=completed, 2=errors
    per_worker = div(total, concurrency)

    start = System.monotonic_time(:microsecond)

    tasks =
      for _ <- 1..concurrency do
        Task.async(fn ->
          client = Req.new(base_url: base_url, retry: false)

          for _ <- 1..per_worker do
            t0 = System.monotonic_time(:microsecond)

            result =
              case method do
                :get -> Req.get(client, url: path)
                :post -> Req.post(client, url: path, body: body)
              end

            elapsed = System.monotonic_time(:microsecond) - t0

            case result do
              {:ok, %{status: s}} when s < 400 ->
                :counters.add(counter, 1, 1)
                :ets.insert(ets, {:erlang.unique_integer([:monotonic]), elapsed})

              _ ->
                :counters.add(counter, 2, 1)
            end
          end
        end)
      end

    Task.await_many(tasks, 120_000)

    wall_us = System.monotonic_time(:microsecond) - start
    completed = :counters.get(counter, 1)
    errors = :counters.get(counter, 2)

    # Collect latencies
    latencies =
      :ets.tab2list(ets)
      |> Enum.map(fn {_, us} -> us end)
      |> Enum.sort()

    :ets.delete(ets)

    %{
      completed: completed,
      errors: errors,
      wall_ms: div(wall_us, 1000),
      rps: if(wall_us > 0, do: div(completed * 1_000_000, wall_us), else: 0),
      p50: percentile(latencies, 0.50),
      p95: percentile(latencies, 0.95),
      p99: percentile(latencies, 0.99),
      p999: percentile(latencies, 0.999),
      min: List.first(latencies, 0),
      max: List.last(latencies, 0)
    }
  end

  defp print_comparison(rocket, bandit) do
    IO.puts("                        Rocket          Bandit")
    IO.puts("  Requests:       #{pad(fmt_int(rocket.completed))}  #{pad(fmt_int(bandit.completed))}")
    IO.puts("  Errors:         #{pad(fmt_int(rocket.errors))}  #{pad(fmt_int(bandit.errors))}")
    IO.puts("  Throughput:     #{pad(fmt_int(rocket.rps) <> " rps")}  #{pad(fmt_int(bandit.rps) <> " rps")}")
    IO.puts("  Latency p50:    #{pad(fmt_us(rocket.p50))}  #{pad(fmt_us(bandit.p50))}")
    IO.puts("  Latency p95:    #{pad(fmt_us(rocket.p95))}  #{pad(fmt_us(bandit.p95))}")
    IO.puts("  Latency p99:    #{pad(fmt_us(rocket.p99))}  #{pad(fmt_us(bandit.p99))}")
    IO.puts("  Latency p99.9:  #{pad(fmt_us(rocket.p999))}  #{pad(fmt_us(bandit.p999))}")
    IO.puts("  Min/Max:        #{pad(fmt_us(rocket.min) <> "/" <> fmt_us(rocket.max))}  #{pad(fmt_us(bandit.min) <> "/" <> fmt_us(bandit.max))}")
  end

  defp percentile([], _), do: 0
  defp percentile(sorted, p) do
    idx = trunc(length(sorted) * p) |> min(length(sorted) - 1) |> max(0)
    Enum.at(sorted, idx)
  end

  defp pad(str), do: String.pad_leading(str, 14)

  defp fmt_int(n) when n >= 1_000_000, do: "#{Float.round(n / 1_000_000, 1)}M"
  defp fmt_int(n) when n >= 1_000, do: "#{Float.round(n / 1_000, 1)}K"
  defp fmt_int(n), do: "#{n}"

  defp fmt_us(us) when us >= 1_000_000, do: "#{Float.round(us / 1_000_000, 2)}s"
  defp fmt_us(us) when us >= 1_000, do: "#{Float.round(us / 1_000, 2)}ms"
  defp fmt_us(us), do: "#{us}μs"
end

# Parse CLI args
{opts, _} = OptionParser.parse!(System.argv(), strict: [concurrency: :integer, requests: :integer])
Bench.run(opts)
