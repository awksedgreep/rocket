defmodule Rocket.ConnectionIncrementalTest do
  use ExUnit.Case

  defmodule Handler do
    def handle(req) do
      Rocket.Response.send_resp(req, 200, req.path <> ":" <> req.body)
    end
  end

  setup do
    supervisor = start_supervised!({Rocket, port: 0, handler: Handler})
    [{Rocket.Listener, listener, _, _}] = Supervisor.which_children(supervisor)
    %{listen_socket: socket} = :sys.get_state(listener)
    {:ok, %{port: port}} = :socket.sockname(socket)
    {:ok, client} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], 2000)
    on_exit(fn -> :gen_tcp.close(client) end)
    %{client: client}
  end

  test "resets previous length across keep-alive and a partially pipelined POST", %{
    client: socket
  } do
    prefix = "GET /first HTTP/1.1\r\nX-Padding: " <> String.duplicate("v", 512) <> "\r"
    :ok = :gen_tcp.send(socket, prefix)
    assert {:error, :timeout} = :gen_tcp.recv(socket, 0, 30)

    # The next request is much shorter than the first incomplete prefix. A stale
    # previous_length would raise badarg, or skip its header terminator.
    :ok = :gen_tcp.send(socket, "\n\r\nPOST /second HTTP/1.1\r\nContent-Length: 5\r")
    {"/first:", rest} = response(socket)
    assert rest == ""
    assert {:error, :timeout} = :gen_tcp.recv(socket, 0, 30)

    # Finish the next request, include its body, and pipeline another request.
    :ok = :gen_tcp.send(socket, "\n\r\nhelloGET /third HTTP/1.1\r\n\r\n")
    {"/second:hello", rest} = response(socket)
    {"/third:", ""} = response(socket, rest)

    # A subsequent recv starts a fresh parse, too.
    :ok = :gen_tcp.send(socket, "GET /fourth HTTP/1.1\r\nConnection: close\r\n\r\n")
    {"/fourth:", ""} = response(socket)
    assert {:error, :closed} = :gen_tcp.recv(socket, 0, 2000)
  end

  defp response(socket, buffer \\ "") do
    case :binary.split(buffer, "\r\n\r\n") do
      [head, tail] ->
        assert String.starts_with?(head, "HTTP/1.1 200 ")
        [_, value] = Regex.run(~r/content-length: (\d+)/i, head)
        length = String.to_integer(value)

        if byte_size(tail) >= length do
          {binary_part(tail, 0, length), binary_part(tail, length, byte_size(tail) - length)}
        else
          {:ok, data} = :gen_tcp.recv(socket, 0, 2000)
          response(socket, buffer <> data)
        end

      [_] ->
        {:ok, data} = :gen_tcp.recv(socket, 0, 2000)
        response(socket, buffer <> data)
    end
  end
end
