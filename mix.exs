defmodule Breakout.MixProject do
  use Mix.Project

  def project do
    [
      app: :breakout,
      version: "0.1.0",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      licenses: ["MIT"],
      description: "The Breakout game implemented in Elixir."
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {Breakout.Application, []}
    ]
  end

  defp deps do
    [
      {:egl, git: "https://github.com/erlangsters/egl-1-5", branch: "master"},
      {:gl, git: "https://github.com/erlangsters/opengl-es-3.1", branch: "master"},
      {:glfw, git: "https://github.com/erlangsters/glfw", branch: "master"}
    ]
  end
end
