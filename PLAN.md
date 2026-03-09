# Rocket - High-Performance HTTP Server for the BEAM

A purpose-built HTTP/1.1 server designed for TimelessMetrics and similar embedded
BEAM applications where every microsecond of HTTP overhead matters.

**Goal:** Replace Bandit+Plug with a minimal server that uses NIF-based HTTP
parsing, OTP 28 `socket` module, and direct pattern-match routing. Target
per-request overhead under 10μs (vs ~50-100μs with Bandit+Plug today).

---

## Phase 1: TCP Acceptor Pool + Socket Management

**Goal:** Accept TCP connections using OTP 28 `socket` module with `select_read`
for optimal poll performance. No NIFs yet — just get bytes flowing.

### 1.1 Listener GenServer
- `Rocket.Listener.start_link(port: 8428, handler: MyApp.Router)`
- Opens a listening socket via `:socket.open/3` + `:socket.bind/2` + `:socket.listen/2`
- `SO_REUSEADDR`, `SO_REUSEPORT`, `TCP_NODELAY`
- Configurable backlog (default 1024)

### 1.2 Acceptor Pool
- N acceptor processes (default: `System.schedulers_online()`)
- Each calls `:socket.accept/1` in a loop
- On accept, spawn a `Rocket.Connection` process for the new socket
- Acceptor immediately loops back to accept next connection

### 1.3 Connection Process
- Owns one client socket for its lifetime
- Uses `:socket.setopt(sock, {otp, select_read}, true)` for persistent polling
- Receives `{:"$socket", socket, :select, select_handle}` messages when data ready
- Calls `:socket.recv/2` on select notification
- Accumulates data in a buffer until a complete HTTP request is parsed
- Keep-alive: stays alive after response, waits for next request
- Idle timeout (default 60s) — process exits, socket closes

### 1.4 Supervision
- `Rocket.Supervisor` — top-level
  - `Rocket.Listener` (one per port)
    - `Rocket.AcceptorSup` — `one_for_one` for N acceptors
  - Connection processes are temporary, not supervised (link to acceptor or
    use a `simple_one_for_one`/`DynamicSupervisor` if we want graceful drain)

### Deliverable
Accept TCP connections, recv raw bytes, echo them back. Verify with `curl`.

---

## Phase 2: HTTP Parser NIF (picohttpparser)

**Goal:** Parse HTTP/1.1 requests in C using [picohttpparser](https://github.com/h2o/picohttpparser)
and return structured Erlang terms.

### 2.1 Vendor picohttpparser
- Copy `picohttpparser.c` and `picohttpparser.h` into `c_src/`
- It's ~800 lines, no dependencies, MIT licensed
- Uses SSE4.2 `_mm_cmpestri` for SIMD-accelerated header scanning when available

### 2.2 NIF: `Rocket.HTTP.parse_request/1`
```
Input:  binary (raw TCP buffer)
Output: {:ok, {method, path, query_string, headers, body_offset, minor_version}}
      | :incomplete    (need more data, keep buffering)
      | :error         (malformed request)

Where:
  method       :: binary     "GET", "POST", etc.
  path         :: binary     "/api/v1/query_range" (without query string)
  query_string :: binary     "metric=cpu&start=1700000000" (raw, unparsed)
  headers      :: [{name :: binary, value :: binary}]
  body_offset  :: non_neg_integer  (byte offset where body starts)
  minor_version :: 0 | 1     (HTTP/1.0 or 1.1)
```

### 2.3 NIF: `Rocket.HTTP.parse_query_string/1`
```
Input:  binary (raw query string)
Output: [{key :: binary, value :: binary}]
```
Percent-decoding + `&`/`=` splitting in C. Single pass.

### 2.4 Build System
- `elixir_make` + `cc_precompiler` (same pattern as timeless_metrics)
- `Makefile` with `-O2 -msse4.2` flags (with fallback for non-SSE platforms)
- Precompiled NIF artifacts for linux-x86_64, linux-aarch64, macos-x86_64,
  macos-aarch64

### 2.5 Safety
- `phr_parse_request` is stateless, no allocations — perfect NIF citizen
- Max 100 headers, max 8KB header size (configurable guards before NIF call)
- NIF does zero I/O, pure computation — no dirty scheduler needed
- Budget: ~1-5μs per parse for typical requests

### Deliverable
`Rocket.HTTP.parse_request(binary)` works from `iex`. Benchmark against
Plug's HTTP parser. Expect 5-10x improvement.

---

## Phase 3: Request Handling + Router DSL

**Goal:** Route parsed requests to handler functions. Zero Plug dependency.

### 3.1 Request Struct
```elixir
defstruct [
  :method,          # :get | :post | :put | :delete | :head | :options
  :path,            # "/api/v1/query_range"
  :path_segments,   # ["api", "v1", "query_range"]
  :query_string,    # "metric=cpu&start=1700000000"
  :query_params,    # %{"metric" => "cpu", "start" => "1700000000"} (lazy)
  :headers,         # [{name, value}] from NIF
  :body,            # binary | nil (lazy read for POST)
  :socket,          # socket reference for body reads
  :version          # {1, 1}
]
```

### 3.2 Router Macro
```elixir
defmodule MyApp.Router do
  use Rocket.Router

  get "/health" do
    Rocket.Response.send(req, 200, %{status: "ok"})
  end

  post "/api/v1/import/prometheus" do
    body = Rocket.Request.read_body(req)
    # ... handle
    Rocket.Response.send(req, 204)
  end

  get "/api/v1/query_range" do
    params = Rocket.Request.query_params(req)
    # ... handle
    Rocket.Response.json(req, 200, result)
  end

  match _ do
    Rocket.Response.send(req, 404, "not found")
  end
end
```

Under the hood, the macro compiles to a single `dispatch/2` function with
pattern-match clauses on `{method, path_segments}`. No middleware pipeline,
no Conn lifecycle — just function calls.

### 3.3 Response Helpers
```elixir
Rocket.Response.send(req, status)                    # no body
Rocket.Response.send(req, status, body)              # binary body
Rocket.Response.json(req, status, term)              # :json.encode + content-type
Rocket.Response.send_iodata(req, status, headers, iodata)  # full control
```

All response functions format the HTTP response and call `:socket.send/2`
directly. Pre-build common status lines as module attributes at compile time:
`@ok "HTTP/1.1 200 OK\r\n"`, `@no_content "HTTP/1.1 204 No Content\r\n"`, etc.

### 3.4 Path Parameters
```elixir
get "/api/v1/label/:name/values" do
  name = req.path_params["name"]
  # ...
end
```

Compile-time extraction of `:param` segments. At dispatch time, the pattern
match binds the segment and injects it into `req.path_params`.

### Deliverable
Full request→route→handle→response cycle working. Benchmark vs Bandit+Plug.

---

## Phase 4: Body Reading + Keep-Alive

**Goal:** Handle POST bodies correctly, support HTTP/1.1 keep-alive.

### 4.1 Body Reading
- `Rocket.Request.read_body(req)` — read up to `Content-Length` bytes
- `Rocket.Request.read_body(req, max_bytes: 1_000_000)` — with limit
- Body may already be partially in the parse buffer (data after `body_offset`)
- Read remainder from socket if needed
- Return `{:ok, binary}` or `{:error, :too_large}` or `{:error, :timeout}`

### 4.2 Keep-Alive
- After response sent, check `Connection: close` header
- If keep-alive (default for HTTP/1.1): reset buffer, await next request
- Buffer may contain start of next request (pipelining) — feed leftover
  bytes back into parser
- Idle timeout between requests (configurable, default 60s)

### 4.3 100-Continue
- If `Expect: 100-continue` header present, send `HTTP/1.1 100 Continue\r\n\r\n`
  before reading body
- Simple — just a socket write before body recv

### Deliverable
POST with bodies works. Keep-alive connections reused. Verify with `wrk` or
`hey` that connections are reused across requests.

---

## Phase 5: Production Hardening

**Goal:** Make it safe for real workloads.

### 5.1 Limits & Timeouts
- Max header size: 8KB (reject with 431)
- Max body size: configurable per-route (default 1MB, reject with 413)
- Max headers count: 100 (reject with 431)
- Request timeout: 30s from accept to first byte of response
- Idle timeout: 60s between keep-alive requests
- Slow client: read timeout per recv call (5s)

### 5.2 Error Handling
- Malformed request → 400, close connection
- Unknown route → 404
- Handler crash → 500, log, close connection (don't leak connection state)
- Socket errors → clean up, exit connection process

### 5.3 Backpressure
- Max concurrent connections (configurable, default 10_000)
- When at limit: accept but immediately send 503 and close
- `:counters` for active connection count (lock-free)

### 5.4 Logging
- Access log: method, path, status, latency_us (optional, configurable)
- Error log: via Logger
- Minimal allocations in the log path

### 5.5 Graceful Shutdown
- Stop accepting new connections
- Wait for in-flight requests to complete (with timeout)
- Force-close remaining connections

### Deliverable
Survives `wrk -c 1000 -t 10 -d 30s`. No crashes, no leaks, no OOM.

---

## Phase 6: Integration with TimelessMetrics

**Goal:** Drop-in replacement for Bandit+Plug in TimelessMetrics.HTTP.

### 6.1 Adapter Module
- `TimelessMetrics.HTTP` gets a new mode: `server: :rocket` vs `server: :bandit`
- Extract route handlers from the existing Plug router into standalone functions
- Each handler takes a `Rocket.Request` and returns via `Rocket.Response`

### 6.2 Migration Path
```elixir
# Before (Bandit + Plug)
{TimelessMetrics.HTTP, store: :metrics, port: 8428}

# After (Rocket)
{TimelessMetrics.HTTP, store: :metrics, port: 8428, server: :rocket}
```

### 6.3 Benchmark
- Run `bench/realistic_workload.exs` against both `:bandit` and `:rocket` modes
- Measure write latency, query latency, throughput at saturation
- Target: 2-5x improvement in HTTP overhead (the gap between native API and
  HTTP should shrink significantly)

### Deliverable
TimelessMetrics running on Rocket with measurable performance improvement.

---

## Phase 7: Optional Extras (Future)

These are not needed for v1 but worth considering later:

- **TLS via NIF** — wrap `libssl` or `libtls` for native TLS termination
- **HTTP/2** — only if Grafana/Prometheus clients benefit (they generally don't)
- **WebSocket upgrade** — for real-time streaming to timeless_canvas
- **sendfile** — for serving static assets (OpenAPI docs, chart HTML)
- **Response NIF** — `Rocket.HTTP.format_response/3` for formatting the status
  line + headers in C (marginal gain, probably not worth it)
- **Zero-copy body** — pass socket fd + body offset to prometheus_nif, let it
  recv+parse in one NIF call (dangerous but fast)

---

## Non-Goals

- HTTP/2 or HTTP/3 (complexity not justified for our use case)
- WebSocket (separate concern, can layer on later)
- Middleware pipeline (use function composition instead)
- Plug compatibility (clean break, not an adapter)
- General-purpose web framework (this is a server, not Phoenix)

---

## File Structure
```
rocket/
├── c_src/
│   ├── picohttpparser.c      # vendored
│   ├── picohttpparser.h      # vendored
│   └── rocket_nif.c          # our NIF: parse_request, parse_query_string
├── lib/
│   ├── rocket.ex             # top-level API
│   ├── rocket/
│   │   ├── listener.ex       # socket listen + accept pool
│   │   ├── acceptor.ex       # accept loop process
│   │   ├── connection.ex     # per-connection process
│   │   ├── http.ex           # NIF wrapper module
│   │   ├── request.ex        # request struct + helpers
│   │   ├── response.ex       # response formatting + send
│   │   ├── router.ex         # router macro
│   │   └── supervisor.ex     # supervision tree
├── test/
│   ├── rocket_test.exs
│   ├── http_nif_test.exs
│   ├── router_test.exs
│   └── integration_test.exs
├── bench/
│   └── vs_bandit.exs         # comparative benchmark
├── Makefile
├── mix.exs
└── PLAN.md
```

---

## Dependencies

- `elixir_make` — compile C code
- `cc_precompiler` — precompiled NIF artifacts
- `:socket` — OTP 28 (stdlib, no dep)
- `:json` — OTP 27 (stdlib, no dep)
- Zero runtime Hex dependencies
