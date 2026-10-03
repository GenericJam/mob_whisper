defmodule MobWhisper.Model do
  @moduledoc """
  The speech models mob_whisper knows, and getting one onto the device.

  Models are whisper.cpp's quantised GGML files from
  [ggerganov/whisper.cpp on Hugging Face](https://huggingface.co/ggerganov/whisper.cpp),
  pinned to one repository revision and checked against a SHA-256 before use.
  They are downloaded on first use rather than bundled: the default model is
  ~60 MB, more than the rest of a typical Mob APK.

  | Name        | File                      | Size    | Moto G 2021, 4.5 s utterance |
  |-------------|---------------------------|---------|------------------------------|
  | `:base_en`  | `ggml-base.en-q5_1.bin`   | 59.7 MB | ~1.7 s (default)             |
  | `:tiny_en`  | `ggml-tiny.en-q8_0.bin`   | 43.6 MB | ~0.85 s, more mistakes       |

  Both are English-only. A model you ship or fetch yourself is used with
  `{:file, path}` (no checksum: you vouch for it).
  """

  @revision "5359861c739e955e79d9a303bcbc70fb988958b1"
  @base_url "https://huggingface.co/ggerganov/whisper.cpp/resolve/#{@revision}/"

  @catalogue %{
    base_en: %{
      file: "ggml-base.en-q5_1.bin",
      sha256: "4baf70dd0d7c4247ba2b81fafd9c01005ac77c2f9ef064e00dcf195d0e2fdd2f",
      bytes: 59_721_011,
      english_only: true
    },
    tiny_en: %{
      file: "ggml-tiny.en-q8_0.bin",
      sha256: "5bc2b3860aa151a4c6e7bb095e1fcce7cf12c7b020ca08dcec0c6d018bb7dd94",
      bytes: 43_550_795,
      english_only: true
    }
  }

  @type name :: :base_en | :tiny_en
  @type spec :: name() | {:file, Path.t()}

  @doc "The catalogue model names."
  @spec names() :: [name()]
  def names, do: Map.keys(@catalogue)

  @doc "Catalogue entry for `name`: `%{file:, sha256:, bytes:, english_only:, url:}`."
  @spec info(name()) :: map()
  def info(name) do
    case Map.fetch(@catalogue, name) do
      {:ok, entry} ->
        Map.put(entry, :url, @base_url <> entry.file)

      :error ->
        raise ArgumentError,
              "unknown mob_whisper model #{inspect(name)}; known: #{inspect(names())}"
    end
  end

  @doc "Whether `spec` only understands English (a `{:file, _}` model is assumed multilingual)."
  @spec english_only?(spec()) :: boolean()
  def english_only?({:file, _}), do: false
  def english_only?(name), do: info(name).english_only

  @doc "Where `spec` lives (or will live once downloaded) under `dir`."
  @spec path(spec(), Path.t()) :: Path.t()
  def path({:file, path}, _dir), do: path
  def path(name, dir), do: Path.join(dir, info(name).file)

  @doc """
  Make sure `spec` is on disk under `dir` and return its path.

  A catalogue model already present with the right size is used as is (the
  checksum was verified when it was written); otherwise it is downloaded to a
  `.part` file, its SHA-256 checked, and renamed into place. Errors:
  `{:error, {:download, reason}}`, `{:error, :checksum_mismatch}`,
  `{:error, :enoent}` for a missing `{:file, path}`.

  Options: `:url` overrides the download URL (a mirror); `:req_options` are
  merged into the `Req.get/2` options.
  """
  @spec ensure(spec(), Path.t(), keyword()) :: {:ok, Path.t()} | {:error, term()}
  def ensure(spec, dir, opts \\ [])

  def ensure({:file, path}, _dir, _opts) do
    if File.regular?(path), do: {:ok, path}, else: {:error, :enoent}
  end

  def ensure(name, dir, opts) do
    entry = info(name)
    dest = path(name, dir)

    case File.stat(dest) do
      {:ok, %File.Stat{size: size}} when size == entry.bytes ->
        {:ok, dest}

      _ ->
        download(
          Keyword.get(opts, :url, entry.url),
          entry,
          dest,
          Keyword.get(opts, :req_options, [])
        )
    end
  end

  defp download(url, entry, dest, req_options) do
    part = dest <> ".part"
    File.mkdir_p!(Path.dirname(dest))
    File.rm(part)

    options =
      Keyword.merge(
        [into: File.stream!(part), retry: :transient, max_retries: 2, receive_timeout: 60_000],
        req_options
      )

    result = Req.get(url, options)

    with {:ok, %Req.Response{status: 200}} <- result,
         :ok <- verify(part, entry.sha256) do
      File.rename!(part, dest)
      {:ok, dest}
    else
      {:ok, %Req.Response{status: status}} ->
        File.rm(part)
        {:error, {:download, {:http_status, status}}}

      {:error, :checksum_mismatch} = err ->
        File.rm(part)
        err

      {:error, reason} ->
        File.rm(part)
        {:error, {:download, reason}}
    end
  end

  @doc "`:ok` when the file at `path` has SHA-256 `expected` (lowercase hex)."
  @spec verify(Path.t(), String.t()) :: :ok | {:error, :checksum_mismatch}
  def verify(path, expected) do
    actual =
      path
      |> File.stream!(1_048_576)
      |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
      |> :crypto.hash_final()
      |> Base.encode16(case: :lower)

    if actual == expected, do: :ok, else: {:error, :checksum_mismatch}
  end
end
