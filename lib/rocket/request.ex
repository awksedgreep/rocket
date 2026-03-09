defmodule Rocket.Request do
  @moduledoc """
  HTTP request struct built from NIF-parsed data.
  """

  defstruct [
    :method,
    :path,
    :path_segments,
    :query_string,
    :headers,
    :body,
    :socket,
    path_params: %{},
    query_params: nil
  ]

  @doc """
  Lazily parse and cache query params from the query string.
  Uses the NIF-based parser for percent-decoding.
  """
  def query_params(%__MODULE__{query_params: cached}) when is_map(cached), do: cached

  def query_params(%__MODULE__{query_string: qs} = req) when is_binary(qs) and qs != "" do
    params = qs |> Rocket.HTTP.parse_query_string() |> Map.new()
    {params, %{req | query_params: params}}
  end

  def query_params(%__MODULE__{} = req), do: {%{}, %{req | query_params: %{}}}

  @doc """
  Get a specific query parameter. Returns nil if not found.
  """
  def get_query_param(%__MODULE__{} = req, key) do
    {params, _req} = query_params(req)
    Map.get(params, key)
  end

  @doc """
  Get a header value by name (case-sensitive match against raw header name).
  Returns nil if not found.
  """
  def get_header(%__MODULE__{headers: headers}, name) do
    case List.keyfind(headers, name, 0) do
      {_, value} -> value
      nil -> nil
    end
  end

  @doc """
  Build a Request struct from NIF parse results.
  """
  def build(method, path, query_string, headers, body, socket) do
    segments = String.split(path, "/", trim: true)

    %__MODULE__{
      method: method,
      path: path,
      path_segments: segments,
      query_string: query_string,
      headers: headers,
      body: body,
      socket: socket
    }
  end
end
