defmodule Rocket.Handler do
  @moduledoc """
  Behaviour for Rocket request handlers.
  """

  @callback handle(req :: map()) :: :ok | {:error, term()}
end
