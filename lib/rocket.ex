defmodule Rocket do
  @moduledoc """
  High-performance HTTP/1.1 server for the BEAM.

  Uses OTP 28 `socket` module with NIF-based HTTP parsing for minimal
  per-request overhead.

  ## Usage

      # In your supervision tree:
      children = [
        {Rocket, port: 8080, handler: MyApp.Router}
      ]

      # Or standalone:
      Rocket.start_link(port: 8080, handler: MyApp.Router)
  """

  def start_link(opts) do
    Rocket.Supervisor.start_link(opts)
  end

  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.get(opts, :port, 8080)},
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor
    }
  end
end
