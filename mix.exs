defmodule Rocket.MixProject do
  use Mix.Project

  @version "0.1.0"

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
      {:elixir_make, "~> 0.9", runtime: false}
    ]
  end
end
