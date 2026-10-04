import Config

# The plugin's own test runs drive MobWhisper.Server with a scripted native
# layer (no microphone, no model, no NIF on the host). Host apps never load
# this file: a dependency's config/ isn't evaluated by its parent project.
if config_env() == :test do
  config :mob_whisper,
    native: MobWhisper.FakeNative,
    model: {:file, Path.join(System.tmp_dir!(), "mob_whisper_test_model.bin")},
    threads: 2
end
