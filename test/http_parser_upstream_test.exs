defmodule Rocket.HTTPParserUpstreamTest do
  use ExUnit.Case, async: true

  # Port of every test_request PARSE case from h2o/picohttpparser test.c.
  # Copyright/license and source revisions: picohttpparser/PROVENANCE.md.
  @external_resource Path.join(__DIR__, "picohttpparser/requests.json")
  @vectors @external_resource |> File.read!() |> :json.decode()

  for vector <- @vectors do
    @vector vector

    test "upstream request: #{vector["name"]}" do
      vector = @vector
      input = Base.decode16!(vector["input_hex"], case: :lower)
      expected = expected(vector["expected"])

      assert Rocket.HTTP.parse_request(input) == expected
      assert Rocket.HTTP.parse_request(input, 0) == expected
      assert Rocket.HTTP.parse_request(input, vector["previous"]) == expected
    end
  end

  defp expected("error"), do: :error
  defp expected("incomplete"), do: :incomplete

  defp expected(vector) do
    decode = &Base.decode16!(&1, case: :lower)

    headers =
      Enum.map(vector["headers_hex"], fn [name, value] -> {decode.(name), decode.(value)} end)

    {:ok,
     {:get, decode.(vector["path_hex"]), decode.(vector["query_hex"]), headers, vector["offset"],
      vector["version"]}}
  end
end
