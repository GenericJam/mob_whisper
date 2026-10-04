defmodule MobWhisper.AudioTest do
  use ExUnit.Case, async: true

  alias MobWhisper.Audio

  defp silence(ms), do: :binary.copy(<<0::16>>, ms * 16)

  describe "audio_ctx/1" do
    test "covers the audio plus a margin, in steps of 64 encoder frames" do
      # 4.5 s = 225 frames → 225 + 128 margin → 384 (the setting measured on the Moto)
      assert Audio.audio_ctx(silence(4_500)) == 384
      # 10 s = 500 frames → 628 → 640
      assert Audio.audio_ctx(silence(10_000)) == 640
    end

    test "never goes below 256 frames for very short clips" do
      assert Audio.audio_ctx(silence(200)) == 256
      assert Audio.audio_ctx(<<>>) == 256
    end

    test "uses the full 30 s window (0) once the clip needs it" do
      assert Audio.audio_ctx(silence(26_000)) == 1472
      assert Audio.audio_ctx(silence(27_500)) == 0
      assert Audio.audio_ctx(silence(90_000)) == 0
    end
  end

  test "duration_ms/1 counts 16 kHz s16 samples" do
    assert Audio.duration_ms(silence(1_234)) == 1_234
  end

  test "peak/1 is the largest absolute sample, including -32768" do
    assert Audio.peak(<<10::little-signed-16, -300::little-signed-16, 5::little-signed-16>>) ==
             300

    assert Audio.peak(<<-32_768::little-signed-16>>) == 32_768
    assert Audio.peak(silence(10)) == 0
  end

  describe "clean_text/1" do
    test "trims whisper's leading space and collapses whitespace" do
      assert Audio.clean_text("  Please remind me   to buy milk. ") ==
               "Please remind me to buy milk."
    end

    test "drops non-speech markers, leaving nothing for pure noise" do
      assert Audio.clean_text(" [BLANK_AUDIO]") == ""
      assert Audio.clean_text(" (wind blowing) ") == ""
      assert Audio.clean_text("[Music] *laughs*") == ""
      assert Audio.clean_text(" Hello [BLANK_AUDIO] there.") == "Hello there."
    end
  end
end
