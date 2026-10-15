# Request parser buffer sharing and incremental completeness checks

Rocket's picohttpparser already returns pointers into the input buffer without
allocating. The original NIF subsequently copied the path, query string, every
header name, and every header value into new BEAM binaries. On fragmented input,
the connection loop also supplied `last_len = 0` on every parse attempt, causing
the parser to rescan an accumulating incomplete request.

This change uses the existing C parser and exposes its existing completeness
optimization. No parser source, grammar, routing, socket, body-framing, query
decoding, or server configuration changes are included.

## Behavior and API

- Nonempty request fields use `enif_make_sub_binary` against the original input
  term. Empty fields use an empty binary; pico's nameless folded-header entries
  can have a NULL pointer, so pointer subtraction is deliberately avoided there.
- `Rocket.HTTP.parse_request/1` remains available and preserves the public value
  format: `{:ok, {method, path, query, headers, body_offset, minor_version}}`,
  `:incomplete`, or `:error`. Its returned fields can now share backing storage.
- `Rocket.HTTP.parse_request(input, previous_length)` adds incremental input
  support. The length must be a nonnegative integer at most `byte_size(input)`;
  invalid arguments raise `ArgumentError` before calling pico.
- Supply zero for a new request. A nonzero length must describe a previously
  **incomplete prefix of that same request**. It is not consumed bytes or a
  resumable parser cursor. Pico checks the new suffix and its terminator overlap
  before reparsing a completed header section.
- The connection loop supplies the old buffer length only after `:incomplete`.
  Fresh reads after a completed request and pipelined leftovers start with zero.
- Percent-decoded query parameters continue to use owned copied binaries:
  decoded bytes are not slices of the original input.

## Buffer lifetime tradeoff

Sub-binaries can retain their entire parent allocation. Retaining a long path or
header can therefore retain a large request body, other pipelined requests, or
the parent of an input that was itself a sub-binary. This changes memory lifetime
even though the public binary values are unchanged.

Copy fields that must outlive request processing when retaining the original
buffer is undesirable. Derived path segments or path parameters may also
inherit backing references, so copy the particular values you retain:

```elixir
retained_path = :binary.copy(req.path)
retained_headers = Enum.map(req.headers, fn {name, value} ->
  {:binary.copy(name), :binary.copy(value)}
end)
```

The VM may copy small fields automatically. On the recorded OTP 29.1.1 run,
retaining a 6-byte path referenced only 6 bytes both before and after. A 128-byte
path in a buffer containing a 1 MiB body referenced 128 bytes before and
**1,048,738 bytes** after. That probe measures backing storage, not total
application memory or allocation throughput. The optimization is most appropriate
when parsed fields remain request-scoped; long-lived consumers should make the
copy decision explicitly.

## Correctness coverage

`mix test` passes **86 ExUnit tests** on the recorded local toolchain:

- All 43 existing Rocket tests, including keep-alive, pipelining, POST bodies,
  `Expect: 100-continue`, error responses, and connection limits.
- A byte-exact port of **every one of the 34 upstream request `PARSE` cases** to
  the public NIF, checking `/1`, `/2` with zero, and `/2` with the upstream
  previous length. Successful requests check every returned field. This
  preserves tests for invalid UTF-8, NUL/DEL/control bytes, obsolete folding,
  empty values, whitespace trimming, multiple spaces, and partial input.
- Every byte-length prefix of CRLF, bare-LF, and POST examples; invalid previous
  lengths; incomplete-to-malformed CR transitions; the 100/101-header boundary;
  and empty query/folded-header fields.
- Shared-field validity after the input owner's exit and GC, and correct offsets
  when the NIF's input is itself a sub-binary.
- An integration regression that fragments a large first request, supplies a
  shorter partially pipelined POST, then pipelines another request after its
  body and finishes with a fresh keep-alive read. This checks all reset points
  for `previous_length` and parses responses by their content length.

`make test-pico` runs the **unmodified original C suite**, including guard-page
boundary tests, request/response/header parsers, and chunked decoding, against
Rocket's bundled C source. It produces **299 passing TAP lines including subtest
summaries**. The suite is pinned to pico revision
`465a7ff09fbd3432fe56c673451f5460154d1f07`; its picotest helper is pinned to
`70b9797596d81896cba49e5918fd5b1edf57269b`. Original copyright/license notices are
preserved. See `test/picohttpparser/PROVENANCE.md`. CI runs this target too.
The public NIF only exposes request parsing, so internal partial-output pointers
and response/header-only/chunked APIs remain covered by the original C suite.

```sh
mix deps.get
mix compile --warnings-as-errors
make test-pico
mix test
mix format --check-formatted lib/rocket/http.ex lib/rocket/connection.ex \
  test/http_parser_upstream_test.exs test/http_incremental_test.exs \
  test/connection_incremental_test.exs bench/parser.exs mix.exs
```

## Direct upstream before/after measurements

Captured October 15, 2026 on `Arnolds-Mac-mini-295`, Apple M1, 8 cores,
16 GiB RAM, macOS 27.0.1 / Darwin 27.0.0 arm64, Elixir 1.20.4,
OTP 29.1.1 / ERTS 17.1, 8 schedulers, Apple Clang 21.0.0, C `-O2`.

The baseline is unchanged upstream `c2b81ddd5e930ccc4812fb688a3226151512536a`
(unreleased version 0.2.5); the comparison uses this patch applied to that base.
Each variant runs in a **fresh VM in its own worktree** with the same benchmark
file. Five paired rounds alternate before/after ordering: before first on odd
rounds, after first on even rounds. Each complete-request sample runs 250,000
requests after 2,000 warmup calls and an explicit GC. Timers exclude compilation,
startup, fixture construction, and parity checks, while including NIF calls,
result construction, and resulting BEAM GC.

Fixtures:

- `hello`: 40 bytes, HTTP/1.1 GET with one Host header.
- `headers24`: 2,291 bytes, GET with a query, Host, and 24 additional named
  headers whose values are 80 bytes each.
- `post1k`: 1,091 bytes, POST with Host, Content-Length, query, and a 1,024-byte
  body already in the buffer. Only its headers are parsed.
- Fragmentation: the header-heavy fixture arrives as **72 growing prefixes** in
  32-byte increments. Each sample reconstructs 3,472 requests. All prefixes are
  precomputed; there are no socket reads or concatenation costs in this probe.
  The fragmented path warms up for 100 reconstructed requests.

Five-sample medians, **nanoseconds per complete or reconstructed request**:

| Workload | Original `/1` | Shared `/1` | Shared `/2`, previous=0 |
|---|---:|---:|---:|
| Hello | 92.1 | 88.5 | 89.1 |
| 24 extra headers | 3,450.1 | 1,462.6 | 1,468.0 |
| POST with 1 KiB body | 132.5 | 128.8 | 130.4 |

| Fragmented 24-header request | Median ns | Sample min–max ns |
|---|---:|---:|
| Original `/1`, full rescan | 30,847.1 | 30,384.5–34,148.0 |
| Shared `/1`, full rescan | 27,921.1 | 27,884.2–28,017.3 |
| Shared `/2`, previous incomplete length | 4,632.8 | 4,607.4–4,645.2 |

The header-heavy full-NIF cost falls by approximately **58% (2.35× faster)**.
The combined fragmented-input cost falls by approximately **85% (6.66× faster)**.
Using shared results while continuing to rescan the whole incomplete buffer
provides only a modest fragmented-input improvement; the previous-length hint
accounts for most of that gain. Tiny and POST-header timings are close enough
that no material speedup is claimed for them.

Every sample, toolchain metadata, source SHA-256 fingerprints, fixture sizes,
and retention probes are stored in `docs/benchmarks/parser-before.json` and
`docs/benchmarks/parser-after.json`. The recorded source hashes identify the
tested working-tree patch separately from the common base revision. This is a
local desktop probe, not an isolated benchmark host or a confidence interval.

### Reproduce

```sh
# Run from a checkout containing the proposed benchmark.
mix deps.get
MIX_ENV=test PARSER_LABEL=after PARSER_RECORD=/tmp/parser-after.json \
  PARSER_ITERATIONS=250000 PARSER_TRIALS=5 mix run bench/parser.exs
```

To compare the unchanged base, copy `bench/parser.exs` to a neutral location such
as `/tmp/rocket-parser-bench.exs`, create a separate worktree at the baseline
revision above, resolve its existing dependencies, and run:

```sh
# Run from the baseline worktree; this script detects the available NIF arities.
MIX_ENV=test PARSER_LABEL=before PARSER_RECORD=/tmp/parser-before.json \
  PARSER_ITERATIONS=250000 PARSER_TRIALS=5 mix run /tmp/rocket-parser-bench.exs
```

For the paired capture described above, use `PARSER_TRIALS=1` and repeat both
commands in alternating order across five rounds, keeping each JSON file.
Do not run them concurrently. CPU features and OTP's binary representation can
change the result on other machines; remeasure on the deployment architecture.

## Measurement limits

The measurements above cover full-NIF calls and reconstructed fragmented input.
They do not include an external HTTP load generator or establish an end-to-end
HTTP throughput improvement for this patch.

Faster NIFs do not imply a proportional server speedup. The parser-only core is
unchanged, and real requests also pay socket, routing, response, application,
TLS/proxy, and network costs. The fragmented probe excludes TCP timing and input
buffer growth. A quiet external load-generator/server pair, CPU profiling, and
long-lived-field memory workloads are the next checks before making deployment
capacity or overall memory-efficiency claims.
