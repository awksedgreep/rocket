# Upstream parser test provenance

`test.c` is unmodified from h2o/picohttpparser revision
`465a7ff09fbd3432fe56c673451f5460154d1f07` (retrieved 2026-10-15).
`picotest/picotest.c` and `picotest/picotest.h` are unmodified from its pinned
h2o/picotest submodule revision `70b9797596d81896cba49e5918fd5b1edf57269b`.
The copyright and MIT/Perl license notices remain in the sources.

`requests.json` ports **every PARSE case in test_request** into byte-exact
Elixir-readable golden inputs, previous lengths, and expected public results.
It preserves invalid UTF-8, NUL/DEL/control bytes, folding, whitespace,
incomplete requests, and last_len tests. Successful cases check all returned
fields, not just status. Internal C partial-output pointers have no equivalent
in Rocket's public incomplete/error ABI; the original C suite checks those.

`make test-pico` runs all seven original C subtests against Rocket's bundled
parser, including response/header/chunked tests, plus the guard-page setup
assertion (299 passing TAP lines including subtest summaries).
`test/http_parser_upstream_test.exs` ports all request cases to both public NIF
arities; `mix test` checks the tuple fields and incremental statuses.
No parser source or grammar changes are included in this optimization.
