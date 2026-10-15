# Full-NIF and growing-prefix benchmark. Run the same file on both revisions:
# PARSER_LABEL=before PARSER_RECORD=/tmp/before.json mix run bench/parser.exs
# PARSER_LABEL=after PARSER_RECORD=/tmp/after.json mix run bench/parser.exs
# Optional: PARSER_ITERATIONS=250000 PARSER_TRIALS=5 (defaults below).
# This is an in-process parser probe, not an HTTP throughput benchmark.
defmodule Rocket.ParserBench do
  def run do
    iterations = positive!("PARSER_ITERATIONS", 250_000)
    trials = positive!("PARSER_TRIALS", 5)
    Code.ensure_loaded!(Rocket.HTTP)
    incremental? = function_exported?(Rocket.HTTP, :parse_request, 2)

    headers =
      Enum.map(1..24, fn n -> ["X-Bench-#{n}: ", String.duplicate("v", 80), "\r\n"] end)

    fixtures = [
      {"hello", "GET /hello HTTP/1.1\r\nHost: localhost\r\n\r\n"},
      {"headers24",
       IO.iodata_to_binary(["GET /hello?x=1 HTTP/1.1\r\nHost: localhost\r\n", headers, "\r\n"])},
      {"post1k",
       "POST /echo?q=ok HTTP/1.1\r\nHost: localhost\r\nContent-Length: 1024\r\n\r\n" <>
         String.duplicate("b", 1024)}
    ]

    complete =
      for trial <- 1..trials, {fixture, input} <- fixtures do
        functions = [{"full_nif_1", &Rocket.HTTP.parse_request/1}]

        functions =
          if incremental?,
            do:
              functions ++ [{"full_nif_2", fn bytes -> Rocket.HTTP.parse_request(bytes, 0) end}],
            else: functions

        for {layer, function} <- functions do
          repeat(function, input, 2000, 0)
          :erlang.garbage_collect()
          {us, checksum} = :timer.tc(fn -> repeat(function, input, iterations, 0) end)
          {:ok, {_, _, _, _, offset, _}} = function.(input)
          if checksum != offset * iterations, do: raise("body-offset checksum mismatch")

          %{layer: layer, fixture: fixture, trial: trial, ns_per_request: us * 1000 / iterations}
        end
      end

    {_, input} = Enum.at(fixtures, 1)
    sizes = (Enum.to_list(32..byte_size(input)//32) ++ [byte_size(input)]) |> Enum.uniq()
    prefixes = Enum.map(sizes, &binary_part(input, 0, &1))
    count = max(div(iterations, length(prefixes)), 10)
    functions = [{"fragmented_fresh", fn bytes, _ -> Rocket.HTTP.parse_request(bytes) end}]

    functions =
      if incremental?,
        do: functions ++ [{"fragmented_incremental", &Rocket.HTTP.parse_request/2}],
        else: functions

    fragmented =
      for trial <- 1..trials, {layer, function} <- functions do
        # Check every prefix outside the timed loop, including the final result.
        Enum.reduce(prefixes, 0, fn prefix, previous ->
          if function.(prefix, previous) != Rocket.HTTP.parse_request(prefix),
            do: raise("prefix result mismatch")

          byte_size(prefix)
        end)

        reconstruct(function, prefixes, 100, 0)
        :erlang.garbage_collect()
        {us, checksum} = :timer.tc(fn -> reconstruct(function, prefixes, count, 0) end)
        if checksum != byte_size(input) * count, do: raise("fragment checksum mismatch")

        %{
          layer: layer,
          fixture: "headers24",
          trial: trial,
          ns_per_request: us * 1000 / count,
          parser_calls_per_request: length(prefixes)
        }
      end

    retention =
      for size <- [6, 128] do
        path = "/" <> String.duplicate("p", size - 1)

        input =
          :binary.copy(
            "GET #{path} HTTP/1.1\r\nHost: localhost\r\n\r\n" <> String.duplicate("b", 1_048_576)
          )

        {:ok, {_, path, _, _, _, _}} = Rocket.HTTP.parse_request(input)
        %{path_bytes: byte_size(path), backing_bytes: :binary.referenced_byte_size(path)}
      end

    rows = List.flatten(complete) ++ fragmented

    metadata = %{
      label: System.get_env("PARSER_LABEL", "current"),
      date_utc: DateTime.utc_now() |> DateTime.to_iso8601(),
      revision: command("git", ["rev-parse", "HEAD"]),
      elixir: System.version(),
      otp:
        File.read!(
          Path.join([
            to_string(:code.root_dir()),
            "releases",
            to_string(:erlang.system_info(:otp_release)),
            "OTP_VERSION"
          ])
        )
        |> String.trim(),
      erts: to_string(:erlang.system_info(:version)),
      schedulers: System.schedulers_online(),
      uname: command("uname", ["-a"]),
      cc: command("cc", ["--version"]) |> String.split("\n") |> hd(),
      uptime: command("uptime", []),
      source_sha256:
        Map.new(["c_src/rocket_nif.c", "lib/rocket/connection.ex"], fn path ->
          {path, :crypto.hash(:sha256, File.read!(path)) |> Base.encode16(case: :lower)}
        end),
      incremental_api: incremental?,
      iterations: iterations,
      trials: trials
    }

    report = %{
      metadata: metadata,
      fixtures:
        Enum.map(fixtures, fn {name, input} -> %{name: name, bytes: byte_size(input)} end),
      measurements: rows,
      retention: retention
    }

    path = System.get_env("PARSER_RECORD", "/tmp/rocket-parser.json")
    File.write!(path, :json.encode(report))
    IO.puts("Recorded #{path}")

    for {{layer, fixture}, samples} <- Enum.group_by(rows, &{&1.layer, &1.fixture}) |> Enum.sort() do
      values = Enum.map(samples, & &1.ns_per_request) |> Enum.sort()

      IO.puts(
        "#{layer} / #{fixture}: median #{Float.round(Enum.at(values, div(length(values), 2)), 1)} ns; range #{Float.round(hd(values), 1)}..#{Float.round(List.last(values), 1)}"
      )
    end

    IO.inspect(retention, label: "Retained backing bytes")
  end

  defp repeat(_function, _input, 0, checksum), do: checksum

  defp repeat(function, input, remaining, checksum) do
    {:ok, {_, _, _, _, offset, _}} = function.(input)
    repeat(function, input, remaining - 1, checksum + offset)
  end

  defp reconstruct(_function, _prefixes, 0, checksum), do: checksum

  defp reconstruct(function, prefixes, remaining, checksum) do
    size =
      Enum.reduce(prefixes, 0, fn prefix, previous ->
        function.(prefix, previous)
        byte_size(prefix)
      end)

    reconstruct(function, prefixes, remaining - 1, checksum + size)
  end

  defp positive!(name, default) do
    case Integer.parse(System.get_env(name, to_string(default))) do
      {value, ""} when value > 0 -> value
      _ -> raise ArgumentError, "#{name} must be a positive integer"
    end
  end

  defp command(executable, args) do
    {output, 0} = System.cmd(executable, args)
    String.trim(output)
  end
end

Rocket.ParserBench.run()
