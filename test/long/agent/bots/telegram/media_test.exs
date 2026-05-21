defmodule Long.Agent.Bots.Telegram.MediaTest do
  use ExUnit.Case, async: true

  alias Long.Agent.Bots.Telegram.Media

  describe "inbound_descriptors/1" do
    test "picks the largest photo by pixel count" do
      msg = %{
        "photo" => [
          %{"file_id" => "small", "width" => 90, "height" => 90},
          %{"file_id" => "large", "width" => 800, "height" => 600},
          %{"file_id" => "medium", "width" => 320, "height" => 320}
        ]
      }

      assert [{:image, "large", nil}] = Media.inbound_descriptors(msg)
    end

    test "documents return :file with file_name preserved" do
      msg = %{"document" => %{"file_id" => "doc1", "file_name" => "report.pdf"}}
      assert [{:file, "doc1", "report.pdf"}] = Media.inbound_descriptors(msg)
    end

    test "videos return :video" do
      msg = %{"video" => %{"file_id" => "vid1", "file_name" => "clip.mp4"}}
      assert [{:video, "vid1", "clip.mp4"}] = Media.inbound_descriptors(msg)
    end

    test "voice notes return :file without a name" do
      msg = %{"voice" => %{"file_id" => "voice1"}}
      assert [{:file, "voice1", nil}] = Media.inbound_descriptors(msg)
    end

    test "audio files return :file" do
      msg = %{"audio" => %{"file_id" => "aud1", "file_name" => "song.mp3"}}
      assert [{:file, "aud1", "song.mp3"}] = Media.inbound_descriptors(msg)
    end

    test "text-only messages have no media descriptors" do
      assert Media.inbound_descriptors(%{"text" => "hello"}) == []
    end

    test "photo + caption: caption belongs to text path, media stays in descriptors" do
      msg = %{
        "photo" => [%{"file_id" => "p1", "width" => 100, "height" => 100}],
        "caption" => "look at this"
      }

      # Caption is consumed by extract_message, not by us; we just
      # return the media descriptor regardless.
      assert [{:image, "p1", nil}] = Media.inbound_descriptors(msg)
    end

    test "multiple media kinds in one message all surface" do
      msg = %{
        "photo" => [%{"file_id" => "p", "width" => 100, "height" => 100}],
        "document" => %{"file_id" => "d", "file_name" => "x.txt"}
      }

      descriptors = Media.inbound_descriptors(msg)
      assert {:image, "p", nil} in descriptors
      assert {:file, "d", "x.txt"} in descriptors
    end
  end

  describe "download_all/4" do
    setup do
      dir = Path.join(System.tmp_dir!(), "telegram-media-test-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf!(dir) end)
      {:ok, dir: dir}
    end

    test "downloads each descriptor and returns absolute paths", %{dir: dir} do
      http = fn opts ->
        url = Keyword.fetch!(opts, :url)

        cond do
          url =~ "getFile" ->
            {:ok,
             %Req.Response{
               status: 200,
               body: %{"ok" => true, "result" => %{"file_path" => "photos/file_5.jpg"}}
             }}

          url =~ "/file/bot" ->
            {:ok, %Req.Response{status: 200, body: "BYTES"}}
        end
      end

      assert [path] = Media.download_all([{:image, "p1", nil}], dir, "tok", http)
      assert File.read!(path) == "BYTES"
      assert Path.extname(path) == ".jpg"
    end

    test "preserves the document's file_name", %{dir: dir} do
      http = fn opts ->
        url = Keyword.fetch!(opts, :url)

        cond do
          url =~ "getFile" ->
            {:ok,
             %Req.Response{
               status: 200,
               body: %{"ok" => true, "result" => %{"file_path" => "documents/file_8.bin"}}
             }}

          url =~ "/file/bot" ->
            {:ok, %Req.Response{status: 200, body: "PDF"}}
        end
      end

      assert [path] = Media.download_all([{:file, "d1", "report.pdf"}], dir, "tok", http)
      assert Path.basename(path) == "report.pdf"
    end

    test "logs and skips a failed download", %{dir: dir} do
      http = fn _opts ->
        {:ok, %Req.Response{status: 404, body: %{"ok" => false}}}
      end

      # Bad attachment shouldn't abort the dispatch; the failure is
      # logged at warn and we get [] back.
      assert Media.download_all([{:image, "p1", nil}], dir, "tok", http) == []
    end

    test "sanitizes path-traversal attempts in file_name", %{dir: dir} do
      http = fn opts ->
        url = Keyword.fetch!(opts, :url)

        cond do
          url =~ "getFile" ->
            {:ok,
             %Req.Response{
               status: 200,
               body: %{"ok" => true, "result" => %{"file_path" => "documents/file_8"}}
             }}

          url =~ "/file/bot" ->
            {:ok, %Req.Response{status: 200, body: "PWN"}}
        end
      end

      assert [path] = Media.download_all([{:file, "d", "../../etc/passwd"}], dir, "tok", http)
      assert Path.dirname(path) == Path.expand(dir)
    end

    test "empty descriptor list skips the mkdir entirely", %{dir: dir} do
      http = fn _ -> flunk("should not call HTTP for empty descriptors") end
      assert Media.download_all([], dir, "tok", http) == []
      refute File.exists?(dir)
    end
  end

  describe "endpoint_for/1" do
    test "image → sendPhoto / :photo" do
      assert Media.endpoint_for(:image) == {"sendPhoto", :photo}
    end

    test "video → sendVideo / :video" do
      assert Media.endpoint_for(:video) == {"sendVideo", :video}
    end

    test "file (and anything unknown) → sendDocument / :document" do
      assert Media.endpoint_for(:file) == {"sendDocument", :document}
      assert Media.endpoint_for(:something_else) == {"sendDocument", :document}
    end
  end

  describe "send_attachment/3" do
    setup do
      path = Path.join(System.tmp_dir!(), "telegram-send-test-#{System.unique_integer([:positive])}.png")
      File.write!(path, "IMAGEBYTES")
      on_exit(fn -> File.rm(path) end)
      {:ok, path: path}
    end

    test "posts multipart sendPhoto for :image kind", %{path: path} do
      this = self()

      http = fn opts ->
        send(this, {:posted, opts})
        {:ok, %Req.Response{status: 200, body: %{"ok" => true}}}
      end

      state = %{token: "tok", http: http}
      assert {:ok, _} = Media.send_attachment(state, "42", %{path: path, kind: :image, caption: nil})

      assert_receive {:posted, opts}
      assert Keyword.fetch!(opts, :url) =~ "/sendPhoto"

      form = Keyword.fetch!(opts, :form_multipart)
      assert {"chat_id", "42"} in form

      # Photo field carries the file bytes + filename. Req's
      # multipart shape is `{name, {value, opts}}` (NOT a 3-tuple).
      assert Enum.any?(form, fn
               {:photo, {"IMAGEBYTES", opts}} ->
                 Keyword.get(opts, :filename) =~ ~r/\.png$/ and
                   Keyword.get(opts, :content_type) == "image/png"

               _ ->
                 false
             end)
    end

    test "passes caption with parse_mode HTML", %{path: path} do
      this = self()
      http = fn opts -> send(this, {:posted, opts}); {:ok, %Req.Response{status: 200, body: %{}}} end
      state = %{token: "tok", http: http}

      assert {:ok, _} =
               Media.send_attachment(state, "42", %{
                 path: path,
                 kind: :image,
                 caption: "**look** at this"
               })

      assert_receive {:posted, opts}
      form = Keyword.fetch!(opts, :form_multipart)
      assert {"caption", "<b>look</b> at this"} in form
      assert {"parse_mode", "HTML"} in form
    end

    test "routes :file to sendDocument", %{path: path} do
      this = self()
      http = fn opts -> send(this, {:posted, opts}); {:ok, %Req.Response{status: 200, body: %{}}} end
      state = %{token: "tok", http: http}

      assert {:ok, _} =
               Media.send_attachment(state, "42", %{path: path, kind: :file, caption: nil})

      assert_receive {:posted, opts}
      assert Keyword.fetch!(opts, :url) =~ "/sendDocument"
    end

    test "returns {:error, :enoent} when the local file is missing" do
      assert {:error, :enoent} =
               Media.send_attachment(
                 %{token: "tok", http: fn _ -> flunk("should not call API") end},
                 "42",
                 %{path: "/no/such/file", kind: :file, caption: nil}
               )
    end
  end
end
