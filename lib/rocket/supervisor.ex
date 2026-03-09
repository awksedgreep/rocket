defmodule Rocket.Supervisor do
  @moduledoc false
  use Supervisor

  def start_link(opts) do
    port = Keyword.get(opts, :port, 8080)
    Supervisor.start_link(__MODULE__, opts, name: :"rocket_sup_#{port}")
  end

  @impl true
  def init(opts) do
    children = [
      {Rocket.Listener, opts}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
