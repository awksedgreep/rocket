defmodule Rocket.HTTP do
  @moduledoc """
  NIF-based HTTP/1.1 parser powered by picohttpparser.

  ## parse_request/1

  Parses a raw HTTP request binary. Returns one of:

    * `{:ok, {method, path, query_string, headers, body_offset, minor_version}}`
    * `:incomplete` — need more data
    * `:error` — malformed request

  Where:
    * `method` — atom (`:get`, `:post`, etc.)
    * `path` — binary (`"/api/v1/query"`)
    * `query_string` — binary (`"metric=cpu&start=1700000000"`) or `""`
    * `headers` — `[{name_binary, value_binary}, ...]`
    * `body_offset` — integer byte offset where the body starts
    * `minor_version` — 0 or 1 (HTTP/1.0 or 1.1)

  ## parse_query_string/1

  Parses a raw query string with percent-decoding.

  Returns `[{key, value}, ...]` as binaries.
  """

  @on_load :load_nif

  def load_nif do
    path = :filename.join(:code.priv_dir(:rocket), ~c"rocket_nif")

    case :erlang.load_nif(path, 0) do
      :ok -> :ok
      {:error, {:reload, _}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def parse_request(_binary), do: :erlang.nif_error(:not_loaded)
  def parse_query_string(_binary), do: :erlang.nif_error(:not_loaded)
end
