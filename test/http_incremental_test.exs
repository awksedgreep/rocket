defmodule Rocket.HTTPIncrementalTest do
  use ExUnit.Case, async: true

  test "incremental parsing matches a fresh parse at every incomplete byte boundary" do
    requests = [
      "GET /hello?x=1 HTTP/1.1\r\nHost: localhost\r\nX: a\t b  \r\n\r\n",
      "GET /hello HTTP/1.0\nX: value\n\n",
      "POST /echo?q=ok HTTP/1.1\r\nContent-Length: 5\r\n\r\nhello"
    ]

    for request <- requests do
      Enum.reduce(0..byte_size(request), nil, fn size, previous ->
        prefix = binary_part(request, 0, size)
        fresh = Rocket.HTTP.parse_request(prefix)

        if previous do
          assert Rocket.HTTP.parse_request(prefix, previous) == fresh
        end

        if fresh == :incomplete, do: size, else: nil
      end)
    end
  end

  test "invalid previous lengths and inputs raise ArgumentError" do
    for args <- [[123, 0], ["", -1], ["", 1], ["GET", 4], ["GET", 1.0], ["GET", :bad]] do
      assert_raise ArgumentError, fn -> apply(Rocket.HTTP, :parse_request, args) end
    end
  end

  test "previous length equal to an incomplete input length is valid" do
    input = "GET /hello HTTP/1.1\r\nHost: local"
    assert Rocket.HTTP.parse_request(input, byte_size(input)) == :incomplete
  end

  test "a CR followed by a non-LF byte after an incomplete prefix is an error" do
    prefix = "GET /hello HTTP/1.1\r\nX: value\r"
    assert Rocket.HTTP.parse_request(prefix) == :incomplete
    assert Rocket.HTTP.parse_request(prefix <> "X", byte_size(prefix)) == :error
  end

  test "preserves empty query and folded-header fields without dereferencing NULL" do
    input = "GET /? HTTP/1.1\r\nX: \r\n continuation\r\n\r\n"

    assert {:ok, {:get, "/", "", [{"X", ""}, {"", " continuation"}], _, 1}} =
             Rocket.HTTP.parse_request(input)
  end

  test "parsed fields remain valid after the input owner exits and GC runs" do
    parent = self()
    expected_path = "/" <> String.duplicate("p", 127)
    expected_query = "q=" <> String.duplicate("q", 128)
    expected_value = String.duplicate("v", 128)

    {pid, ref} =
      spawn_monitor(fn ->
        input =
          :binary.copy(
            "GET #{expected_path}?#{expected_query} HTTP/1.1\r\nX: #{expected_value}\r\n\r\n" <>
              String.duplicate("b", 1_048_576)
          )

        send(parent, {:parsed, Rocket.HTTP.parse_request(input)})
      end)

    assert_receive {:parsed, {:ok, {:get, path, query, headers, _, 1}}}, 2000
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2000
    :erlang.garbage_collect()
    assert path == expected_path
    assert query == expected_query
    assert headers == [{"X", expected_value}]
  end

  test "field offsets are relative to a sub-binary input" do
    path = "/" <> String.duplicate("p", 127)
    value = String.duplicate("v", 128)
    request = "GET #{path}?q=ok HTTP/1.1\r\nX: #{value}\r\n\r\n"
    parent = :binary.copy(String.duplicate("_", 128) <> request <> String.duplicate("_", 128))
    input = binary_part(parent, 128, byte_size(request))

    assert Rocket.HTTP.parse_request(input) ==
             {:ok, {:get, path, "q=ok", [{"X", value}], byte_size(request), 1}}
  end

  test "enforces the existing 100-header limit" do
    for count <- [100, 101] do
      input = "GET / HTTP/1.1\r\n" <> String.duplicate("X: y\r\n", count) <> "\r\n"
      result = Rocket.HTTP.parse_request(input)
      if count == 100, do: assert(match?({:ok, _}, result)), else: assert(result == :error)
      assert Rocket.HTTP.parse_request(input, 0) == result
    end
  end
end
