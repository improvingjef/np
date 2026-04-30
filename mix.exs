defmodule Np.MixProject do
  use Mix.Project

  @version "0.1.1"
  @source_url "https://github.com/improvingjef/np"

  def project do
    [
      app: :np,
      version: @version,
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      description: description(),
      package: package(),
      docs: docs(),
      source_url: @source_url,
      name: "Np"
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:ecto, "~> 3.10"},
      {:ecto_sql, "~> 3.10"},
      {:jason, "~> 1.4"},

      # Phoenix LiveView is optional — host apps that want the picker UI
      # add it themselves. Marked optional so test-only consumers don't
      # pull it in.
      {:phoenix_live_view, "~> 1.0", optional: true},
      {:phoenix_html, "~> 4.0", optional: true},

      # Test-only deps
      {:postgrex, "~> 0.18", only: :test},
      {:ex_machina, "~> 2.7", only: :test},

      # Docs
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp description do
    "No problem. Acceptance testing for humans — closed predicate vocabulary, " <>
      "three runners (sandbox / live UAT / Playwright), shared with property and " <>
      "live-drift tests."
  end

  defp package do
    [
      maintainers: ["Jef Newsom"],
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib priv/js mix.exs README.md LICENSE CHANGELOG.md)
    ]
  end

  defp docs do
    [
      main: "Np",
      source_ref: "v#{@version}",
      extras: ["README.md", "CHANGELOG.md"]
    ]
  end
end
