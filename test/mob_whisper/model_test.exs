defmodule MobWhisper.ModelTest do
  use ExUnit.Case, async: true

  alias MobWhisper.Model

  @moduletag :tmp_dir

  defp sha256(data), do: :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)

  test "catalogue entries point at a pinned Hugging Face revision with a SHA-256" do
    for name <- Model.names() do
      info = Model.info(name)
      assert info.url =~ ~r|^https://huggingface\.co/ggerganov/whisper\.cpp/resolve/[0-9a-f]{40}/|
      assert String.ends_with?(info.url, info.file)
      assert info.sha256 =~ ~r/^[0-9a-f]{64}$/
    end
  end

  test "an unknown model name raises with the known names" do
    assert_raise ArgumentError, ~r/known: \[/, fn -> Model.info(:large_v3) end
  end

  test "english_only?/1: catalogue models are, a model file is assumed not" do
    assert Model.english_only?(:base_en)
    refute Model.english_only?({:file, "/x/ggml-small.bin"})
  end

  describe "verify/2" do
    test "accepts the matching digest and rejects any other", %{tmp_dir: dir} do
      path = Path.join(dir, "m.bin")
      File.write!(path, "model bytes")

      assert Model.verify(path, sha256("model bytes")) == :ok
      assert Model.verify(path, sha256("other bytes")) == {:error, :checksum_mismatch}
    end
  end

  describe "ensure/3" do
    test "{:file, path} is used as is, or :enoent", %{tmp_dir: dir} do
      path = Path.join(dir, "mine.bin")
      assert Model.ensure({:file, path}, dir) == {:error, :enoent}
      File.write!(path, "x")
      assert Model.ensure({:file, path}, dir) == {:ok, path}
    end

    test "a present catalogue model of the right size is not downloaded again", %{tmp_dir: dir} do
      dest = Model.path(:tiny_en, dir)
      File.write!(dest, :binary.copy(<<0>>, Model.info(:tiny_en).bytes))

      assert Model.ensure(:tiny_en, dir, req_options: [plug: fn _ -> flunk("downloaded") end]) ==
               {:ok, dest}
    end

    test "a download with the wrong checksum is discarded", %{tmp_dir: dir} do
      plug = fn conn -> Plug.Conn.send_resp(conn, 200, "not the model") end

      assert Model.ensure(:tiny_en, dir, req_options: [plug: plug]) ==
               {:error, :checksum_mismatch}

      assert File.ls!(dir) == []
    end

    test "an HTTP error is a download error and leaves nothing behind", %{tmp_dir: dir} do
      plug = fn conn -> Plug.Conn.send_resp(conn, 404, "gone") end

      assert Model.ensure(:base_en, dir, req_options: [plug: plug, retry: false]) ==
               {:error, {:download, {:http_status, 404}}}

      assert File.ls!(dir) == []
    end

    test "a truncated earlier download is replaced, not trusted", %{tmp_dir: dir} do
      File.write!(Model.path(:tiny_en, dir), "partial")
      plug = fn conn -> Plug.Conn.send_resp(conn, 200, "still not the model") end

      assert Model.ensure(:tiny_en, dir, req_options: [plug: plug]) ==
               {:error, :checksum_mismatch}
    end
  end
end
