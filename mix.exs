defmodule Rocket.MixProject do
  use Mix.Project

  @version "0.2.2"
  @source_url "https://github.com/awksedgreep/rocket"

  def project do
    [
      app: :rocket,
      version: @version,
      elixir: "~> 1.18",
      description: "High-performance HTTP/1.1 server for the BEAM using OTP 28 :socket and a picohttpparser NIF.",
      start_permanent: Mix.env() == :prod,
      compilers: [:elixir_make] ++ Mix.compilers(),
      make_clean: ["clean"],
      deps: deps(),
      package: package(),
      source_url: @source_url,
      homepage_url: @source_url,
      docs: [
        main: "readme",
        extras: ["README.md", "LICENSE"]
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:elixir_make, "~> 0.9", runtime: false},
      {:ex_doc, "~> 0.35", only: :dev, runtime: false},
      {:bandit, "~> 1.6", only: :bench},
      {:plug, "~> 1.16", only: :bench},
      {:req, "~> 0.5", only: :bench}
    ]
  end

  defp package do
    [
      maintainers: ["Matthew Cotner"],
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib c_src priv Makefile mix.exs README.md LICENSE .formatter.exs)
    ]
  end
end
