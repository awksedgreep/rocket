defmodule Rocket.EchoHandler do
  @moduledoc """
  Simple echo handler for testing Phase 1.
  Returns the method and path back to the client.
  """
  @behaviour Rocket.Handler

  @impl true
  def handle(req) do
    body = "#{req.method} #{req.path}\n"
    Rocket.Connection.send_response(req.socket, 200, body)
    :ok
  end
end
