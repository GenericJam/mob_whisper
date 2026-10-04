defmodule MobWhisper.MixProject do
  use Mix.Project

  @source_url "https://github.com/GenericJam/mob_whisper"

  def project do
    [
      app: :mob_whisper,
      version: "0.1.0",
      elixir: "~> 1.17",
      deps: deps(),
      aliases: aliases(),
      description:
        "Offline speech-to-text for Mob apps: whisper.cpp on the phone's CPU, " <>
          "as a MobSpeech engine (no Google app / network recogniser needed)",
      package: package(),
      docs: [
        main: "readme",
        extras: ["README.md", "CHANGELOG.md"]
      ],
      source_url: @source_url,
      elixirc_paths: elixirc_paths(Mix.env())
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  def application do
    [extra_applications: [:logger, :crypto], mod: {MobWhisper.Application, []}]
  end

  defp aliases do
    # `mix setup` after cloning installs deps and activates the shared git
    # hooks (.githooks): format / Credo --strict / compile run on every push
    # and the full suite when mix.exs changes — the same gate CI enforces.
    [setup: ["deps.get", "cmd git config core.hooksPath .githooks"]]
  end

  defp deps do
    # :mob_dev is test-only (the manifest tests run the real pre-publish
    # validator; CI's release job signs with `mix mob.plugin.sign`) and never
    # ships. MOB_SPEECH_PATH / MOB_DEV_PATH point at local checkouts while a
    # needed version isn't on Hex yet.
    [
      {:mob, "~> 0.9"},
      speech_dep(),
      {:req, "~> 0.5"},
      {:plug, "~> 1.16", only: [:dev, :test]},
      dev_dep(),
      {:ex_ast, "~> 0.12", only: [:dev, :test], runtime: false},
      {:reach, "~> 2.7", only: [:dev, :test], runtime: false},
      {:recon, "~> 2.5", only: [:dev, :test]},
      # Code quality — Credo + ex_slop (AI-pattern checks) + jump_credo_checks,
      # mirroring mob core's pre-commit gate.
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_slop, "~> 0.4.2", only: [:dev, :test], runtime: false},
      {:jump_credo_checks, "~> 0.1.0", only: [:dev, :test], runtime: false}
    ]
  end

  defp speech_dep do
    case System.get_env("MOB_SPEECH_PATH") do
      nil -> {:mob_speech, "~> 0.1"}
      path -> {:mob_speech, path: path}
    end
  end

  defp dev_dep do
    case System.get_env("MOB_DEV_PATH") do
      nil -> {:mob_dev, "~> 0.7.13", only: [:dev, :test], runtime: false}
      path -> {:mob_dev, path: path, only: [:dev, :test], runtime: false}
    end
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "whisper.cpp" => "https://github.com/ggml-org/whisper.cpp"
      },
      # The native sources + manifest must ship in the package — the host's
      # native build compiles them from deps/mob_whisper/{c_src,priv}.
      files: ~w(lib src c_src priv mix.exs README* CHANGELOG* LICENSE*)
    ]
  end
end
