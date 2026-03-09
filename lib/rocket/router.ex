defmodule Rocket.Router do
  @moduledoc """
  Macro-based router that compiles routes to pattern-match clauses.

  ## Usage

      defmodule MyApp.Router do
        use Rocket.Router

        get "/health" do
          send_resp(req, 200, "ok")
        end

        get "/api/v1/label/:name/values" do
          name = req.path_params["name"]
          json(req, 200, %{name: name})
        end

        post "/api/v1/import/prometheus" do
          body = Rocket.Request.read_body(req)
          send_resp(req, 204)
        end

        match _ do
          send_resp(req, 404, "not found")
        end
      end

  Routes compile to clauses of `dispatch(method, path_segments, req)`.
  Path parameters (`:name`) become wildcard matches that populate
  `req.path_params`.
  """

  defmacro __using__(_opts) do
    quote do
      import Rocket.Router, only: [get: 2, post: 2, put: 2, delete: 2, head: 2, options: 2, patch: 2, match: 2]
      import Rocket.Response, only: [send_resp: 2, send_resp: 3, json: 3]

      Module.register_attribute(__MODULE__, :rocket_routes, accumulate: true)

      @before_compile Rocket.Router
    end
  end

  # --- Route macros ---

  defmacro get(path, do: body) do
    add_route(:get, path, body, __CALLER__)
  end

  defmacro post(path, do: body) do
    add_route(:post, path, body, __CALLER__)
  end

  defmacro put(path, do: body) do
    add_route(:put, path, body, __CALLER__)
  end

  defmacro delete(path, do: body) do
    add_route(:delete, path, body, __CALLER__)
  end

  defmacro head(path, do: body) do
    add_route(:head, path, body, __CALLER__)
  end

  defmacro options(path, do: body) do
    add_route(:options, path, body, __CALLER__)
  end

  defmacro patch(path, do: body) do
    add_route(:patch, path, body, __CALLER__)
  end

  defmacro match({:_, _, _}, do: body) do
    quote do
      @rocket_routes {:catch_all, unquote(Macro.escape(body))}
    end
  end

  # --- Compilation ---

  defp add_route(method, path, body, _caller) do
    quote do
      @rocket_routes {unquote(method), unquote(path), unquote(Macro.escape(body))}
    end
  end

  defmacro __before_compile__(env) do
    routes = Module.get_attribute(env.module, :rocket_routes) |> Enum.reverse()

    clauses = Enum.flat_map(routes, &compile_route/1)

    # Add a default 404 if no catch_all was defined
    has_catch_all = Enum.any?(routes, fn
      {:catch_all, _} -> true
      _ -> false
    end)

    default_clause =
      if has_catch_all do
        []
      else
        [
          quote do
            def dispatch(_method, _segments, req) do
              Rocket.Response.send_resp(req, 404, "Not Found")
            end
          end
        ]
      end

    # The handle/1 entry point called by Connection
    handle_fn = quote do
      def handle(req) do
        dispatch(req.method, req.path_segments, req)
      end
    end

    clauses ++ default_clause ++ [handle_fn]
  end

  defp compile_route({:catch_all, body}) do
    [
      quote do
        def dispatch(_method, _segments, var!(req)) do
          _ = var!(req)
          unquote(body)
        end
      end
    ]
  end

  defp compile_route({method, path, body}) when is_binary(path) do
    segments = String.split(path, "/", trim: true)
    {pattern, param_names} = compile_segments(segments)

    [
      quote do
        def dispatch(unquote(method), unquote(pattern), var!(req)) do
          var!(req) = unquote(inject_path_params(param_names))
          unquote(body)
        end
      end
    ]
  end

  # Compile path segments into a match pattern and extract param names.
  # "/api/v1/label/:name/values" → {["api", "v1", "label", name, "values"], ["name"]}
  defp compile_segments(segments) do
    {patterns, names} =
      Enum.map_reduce(segments, [], fn
        ":" <> name, acc ->
          var = Macro.var(String.to_atom("__param_#{name}__"), __MODULE__)
          {var, [name | acc]}

        literal, acc ->
          {literal, acc}
      end)

    {patterns, Enum.reverse(names)}
  end

  # Generate code to inject path params into req
  defp inject_path_params([]) do
    quote do: var!(req)
  end

  defp inject_path_params(names) do
    pairs =
      Enum.map(names, fn name ->
        var = Macro.var(String.to_atom("__param_#{name}__"), __MODULE__)
        {name, var}
      end)

    map_pairs =
      for {name, var} <- pairs do
        {name, var}
      end

    quote do
      %{var!(req) | path_params: %{unquote_splicing(map_pairs)}}
    end
  end
end
