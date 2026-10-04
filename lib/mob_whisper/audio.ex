defmodule MobWhisper.Audio do
  @moduledoc """
  Pure helpers around a recording: 16 kHz mono signed 16-bit little-endian PCM,
  the format the capture NIF returns and whisper.cpp consumes.
  """

  @rate 16_000
  # whisper's encoder sees 50 frames per second of audio (a 30 s window is 1500).
  @frames_per_second 50
  @full_ctx 1500
  @min_ctx 256
  @ctx_margin 128

  @doc "Sample rate of every recording, in Hz."
  @spec rate() :: pos_integer()
  def rate, do: @rate

  @doc "Length of `pcm` in milliseconds."
  @spec duration_ms(binary()) :: non_neg_integer()
  def duration_ms(pcm) when is_binary(pcm), do: div(byte_size(pcm) * 1000, 2 * @rate)

  @doc """
  The encoder context (`audio_ctx`) to transcribe `pcm` with.

  whisper.cpp always encodes a 30 s window (1500 frames), so a 4 s utterance
  pays for 30 s of encoder work. Encoding only the frames the audio fills, plus
  a margin, cuts transcription time 2-3x on a phone. The margin (128 frames,
  2.6 s) and the floor (256) keep the tail of the utterance from being cut or
  hallucinated over; at 27 s and longer the full window is used (`0`).
  """
  @spec audio_ctx(binary()) :: non_neg_integer()
  def audio_ctx(pcm) when is_binary(pcm) do
    frames = div(byte_size(pcm) * @frames_per_second, 2 * @rate)
    ctx = (frames + @ctx_margin) |> max(@min_ctx) |> round_up(64)
    if ctx >= @full_ctx, do: 0, else: ctx
  end

  defp round_up(n, m), do: div(n + m - 1, m) * m

  @doc """
  Peak absolute sample value of `pcm` (0..32768). A recording whose peak stays
  under a few hundred is silence or a muted microphone.
  """
  @spec peak(binary()) :: non_neg_integer()
  def peak(pcm) when is_binary(pcm) do
    for <<s::little-signed-16 <- pcm>>, reduce: 0 do
      acc -> max(acc, abs(s))
    end
  end

  @doc """
  Tidy whisper's output into dictation text: drop the bracketed non-speech
  markers it emits for silence or noise (`[BLANK_AUDIO]`, `(wind blowing)`,
  `[Music]`), collapse whitespace, trim. Returns `""` when nothing spoken is left.
  """
  @spec clean_text(String.t()) :: String.t()
  def clean_text(text) when is_binary(text) do
    text
    |> String.replace(~r/\[[^\]]*\]|\([^)]*\)|\*[^*]*\*/u, " ")
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end
end
