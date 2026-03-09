defmodule Rocket.EchoHandler do
  @moduledoc """
  Echo handler for testing. Returns request details as JSON.
  """
  @behaviour Rocket.Handler

  @impl true
  def handle(req) do
    body =
      :json.encode(%{
        method: req.method,
        path: req.path,
        query_string: req.query_string,
        headers: Map.new(req.headers),
        body: req.body
      })

    Rocket.Connection.send_response(req.socket, 200, IO.iodata_to_binary(body))
    :ok
  end
end
