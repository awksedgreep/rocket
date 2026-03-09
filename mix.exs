defmodule Rocket.MixProject do
  use Mix.Project

  @version "0.2.1"

  def project do
    [
      app: :rocket,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      compilers: [:elixir_make] ++ Mix.compilers(),
      make_clean: ["clean"],
      deps: deps()
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
      {:bandit, "~> 1.6", only: :bench},
      {:plug, "~> 1.16", only: :bench},
      {:req, "~> 0.5", only: :bench}
    ]
  end
end
