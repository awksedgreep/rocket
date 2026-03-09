# Rocket

High-performance HTTP/1.1 server for the BEAM.

Rocket uses OTP 28's `:socket` module with a [picohttpparser](https://github.com/h2o/picohttpparser) NIF for request parsing. No middleware layers, no protocol abstractions — just raw TCP sockets and pattern-matched routing compiled at build time.

## Status

> **Experimental / early-stage** — Rocket is under active development and not yet production-ready.

Current limitations:

- No TLS/HTTPS
- No HTTP/2
- No WebSockets
- No middleware or Plug compatibility
- No chunked/streaming responses
- Requires OTP 28 (pre-release)

## Performance

**~30x lower latency** than Bandit+Plug, translating to **~3x higher throughput** under load.

Latency (in-process bench, p50):

| Endpoint        | Rocket     | Bandit      | Improvement |
|-----------------|-----------|-------------|-------------|
| GET /health     | 68μs      | 2.1ms       | 30x         |
| GET /json       | 74μs      | 2.2ms       | 30x         |
| POST 1KB body   | 81μs      | 2.3ms       | 28x         |

Throughput (`hey -n 100000 -c 128`, single machine):

| Endpoint        | Rocket       | Bandit       | Speedup |
|-----------------|-------------|-------------|---------|
| GET /health     | 275,918 rps | 84,949 rps  | 3.2x    |
| GET /json       | 262,089 rps | 80,765 rps  | 3.2x    |
| POST 1KB body   | 278,130 rps | 91,789 rps  | 3.0x    |

The throughput gap is narrower because external bench tools (`hey`, `wrk`) spend most of their time in client-side overhead — connection management, response parsing, scheduling — which both servers share equally. Latency measures what Rocket actually controls: parsing, routing, and response construction.

## Requirements

- Elixir ~> 1.18
- OTP 28+
- C compiler (for the picohttpparser NIF)

## Installation

Add `rocket` to your dependencies:

```elixir
def deps do
  [
    {:rocket, "~> 0.2"}
  ]
end
```

## Quick Start

Define a router:

```elixir
defmodule MyApp.Router do
  use Rocket.Router

  get "/health" do
    send_resp(req, 200, "ok")
  end

  get "/api/users/:id" do
    id = req.path_params["id"]
    json(req, 200, %{id: id, name: "Alice"})
  end

  post "/api/users" do
    body = req.body
    json(req, 201, %{status: "created"})
  end

  match _ do
    send_resp(req, 404, "not found")
  end
end
```

Add Rocket to your supervision tree:

```elixir
children = [
  {Rocket, port: 4000, handler: MyApp.Router}
]

Supervisor.start_link(children, strategy: :one_for_one)
```

## Router

`use Rocket.Router` gives you route macros that compile to pattern-match clauses at build time. Every route receives a `req` variable — a `%Rocket.Request{}` struct.

### HTTP Methods

```elixir
get "/path" do ... end
post "/path" do ... end
put "/path" do ... end
delete "/path" do ... end
patch "/path" do ... end
head "/path" do ... end
options "/path" do ... end
```

### Path Parameters

Segments prefixed with `:` become path params:

```elixir
get "/api/v1/label/:name/values" do
  name = req.path_params["name"]
  # ...
end
```

### Catch-All

```elixir
match _ do
  send_resp(req, 404, "not found")
end
```

If omitted, Rocket returns a default 404.

## Request

The `%Rocket.Request{}` struct:

| Field           | Type                        | Description                    |
|-----------------|-----------------------------|--------------------------------|
| `method`        | atom                        | `:get`, `:post`, etc.          |
| `path`          | binary                      | `"/api/v1/query"`              |
| `path_segments` | list                        | `["api", "v1", "query"]`      |
| `query_string`  | binary                      | Raw query string               |
| `headers`       | `[{name, value}]`           | Raw header tuples              |
| `body`          | binary                      | Request body                   |
| `path_params`   | map                         | Matched `:name` segments       |

### Helpers

```elixir
# Lazy-parsed query params (cached after first call)
{params, req} = Rocket.Request.query_params(req)

# Get a single query param
value = Rocket.Request.get_query_param(req, "metric")

# Get a header
token = Rocket.Request.get_header(req, "authorization")
```

## Response

Response functions are auto-imported in router modules:

```elixir
# Plain text / binary response
send_resp(req, 200, "hello")

# Empty response (204, etc.)
send_resp(req, 204)

# JSON response (encoded with :json.encode/1)
json(req, 200, %{status: "ok"})

# Custom headers + iodata body
Rocket.Response.send_iodata(req, 200, [{"content-type", "text/csv"}], csv_data)
```

## Configuration

```elixir
{Rocket,
  port: 8080,             # default: 8080
  handler: MyApp.Router,  # required
  num_acceptors: 16,      # default: System.schedulers_online()
  max_connections: 10_000, # default: 10_000
  max_body: 1_048_576,    # default: 1 MB
  backlog: 1024           # default: 1024
}
```

## Architecture

```
Rocket.Supervisor
  └── Rocket.Listener (GenServer)
        ├── Rocket.Acceptor 1  ─┐
        ├── Rocket.Acceptor 2  ─┤  accept loop → spawn Connection
        ├── ...                 ─┤
        └── Rocket.Acceptor N  ─┘
              └── Rocket.Connection (per-client process)
                    ├── :socket.recv
                    ├── Rocket.HTTP.parse_request (NIF)
                    ├── Router.handle (your code)
                    └── :socket.send
```

- **Listener** opens the TCP socket with `SO_REUSEADDR` / `SO_REUSEPORT` and spawns the acceptor pool
- **Acceptors** call `:socket.accept/1` in a tight loop, hand off each socket to a new Connection process
- **Connection** owns one client socket for its lifetime — handles keep-alive, pipelining, `Expect: 100-continue`, max body enforcement, and connection backpressure via a shared `:counters` ref
- **Rocket.HTTP** is a NIF wrapping picohttpparser — parses method, path, query string, and headers in C, returns Elixir terms

## License

MIT — see [LICENSE](LICENSE).
