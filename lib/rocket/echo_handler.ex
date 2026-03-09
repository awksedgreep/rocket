defmodule Rocket.EchoHandler do
  @moduledoc """
  Echo handler for testing. Demonstrates the Router DSL.
  """
  use Rocket.Router

  get "/health" do
    send_resp(req, 200, "ok")
  end

  get "/echo/:name" do
    json(req, 200, %{name: req.path_params["name"]})
  end

  post "/echo" do
    json(req, 200, %{method: "post", body: req.body})
  end

  match _ do
    json(req, 200, %{
      method: req.method,
      path: req.path,
      query_string: req.query_string
    })
  end
end
