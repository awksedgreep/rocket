defmodule Rocket.HTTPTest do
  use ExUnit.Case

  describe "parse_request/1" do
    test "parses GET request" do
      req = "GET /hello HTTP/1.1\r\nHost: localhost\r\n\r\n"
      {:ok, {method, path, qs, headers, body_offset, ver}} = Rocket.HTTP.parse_request(req)

      assert method == :get
      assert path == "/hello"
      assert qs == ""
      assert headers == [{"Host", "localhost"}]
      assert body_offset == byte_size(req)
      assert ver == 1
    end

    test "parses GET with query string" do
      req = "GET /api/v1/query?metric=cpu&host=web-1 HTTP/1.1\r\nHost: localhost\r\n\r\n"
      {:ok, {method, path, qs, _headers, _offset, _ver}} = Rocket.HTTP.parse_request(req)

      assert method == :get
      assert path == "/api/v1/query"
      assert qs == "metric=cpu&host=web-1"
    end

    test "parses POST request" do
      req = "POST /import HTTP/1.1\r\nHost: localhost\r\nContent-Length: 5\r\n\r\nhello"
      {:ok, {method, path, _qs, headers, body_offset, _ver}} = Rocket.HTTP.parse_request(req)

      assert method == :post
      assert path == "/import"
      assert {"Content-Length", "5"} in headers
      assert binary_part(req, body_offset, byte_size(req) - body_offset) == "hello"
    end

    test "parses multiple headers" do
      req = "GET / HTTP/1.1\r\nHost: localhost\r\nAccept: */*\r\nUser-Agent: test\r\nX-Custom: value\r\n\r\n"
      {:ok, {_m, _p, _q, headers, _o, _v}} = Rocket.HTTP.parse_request(req)

      assert length(headers) == 4
      assert {"Host", "localhost"} in headers
      assert {"Accept", "*/*"} in headers
      assert {"User-Agent", "test"} in headers
      assert {"X-Custom", "value"} in headers
    end

    test "returns :incomplete for partial request" do
      assert Rocket.HTTP.parse_request("GET /hello HTTP/1.1\r\nHost: lo") == :incomplete
      assert Rocket.HTTP.parse_request("GET") == :incomplete
      assert Rocket.HTTP.parse_request("") == :incomplete
    end

    test "returns :error for malformed request" do
      assert Rocket.HTTP.parse_request("GARBLE GARBLE\r\n\r\n") == :error
    end

    test "parses all HTTP methods" do
      for {method_str, method_atom} <- [
        {"GET", :get}, {"POST", :post}, {"PUT", :put},
        {"DELETE", :delete}, {"HEAD", :head}, {"OPTIONS", :options}, {"PATCH", :patch}
      ] do
        req = "#{method_str} / HTTP/1.1\r\nHost: localhost\r\n\r\n"
        {:ok, {method, _, _, _, _, _}} = Rocket.HTTP.parse_request(req)
        assert method == method_atom, "Expected #{method_atom} for #{method_str}"
      end
    end

    test "parses HTTP/1.0" do
      req = "GET / HTTP/1.0\r\nHost: localhost\r\n\r\n"
      {:ok, {_m, _p, _q, _h, _o, ver}} = Rocket.HTTP.parse_request(req)
      assert ver == 0
    end
  end

  describe "parse_query_string/1" do
    test "parses simple key=value pairs" do
      result = Rocket.HTTP.parse_query_string("foo=bar&baz=qux")
      assert result == [{"foo", "bar"}, {"baz", "qux"}]
    end

    test "handles percent-encoded values" do
      result = Rocket.HTTP.parse_query_string("path=%2Fapi%2Fv1&name=hello%20world")
      assert result == [{"path", "/api/v1"}, {"name", "hello world"}]
    end

    test "handles plus as space" do
      result = Rocket.HTTP.parse_query_string("q=hello+world")
      assert result == [{"q", "hello world"}]
    end

    test "handles key without value" do
      result = Rocket.HTTP.parse_query_string("flag&key=val")
      assert result == [{"flag", ""}, {"key", "val"}]
    end

    test "handles empty string" do
      assert Rocket.HTTP.parse_query_string("") == []
    end

    test "handles single pair" do
      assert Rocket.HTTP.parse_query_string("metric=cpu") == [{"metric", "cpu"}]
    end

    test "handles percent-encoded keys" do
      result = Rocket.HTTP.parse_query_string("%6D%65%74ric=cpu")
      assert result == [{"metric", "cpu"}]
    end
  end
end
