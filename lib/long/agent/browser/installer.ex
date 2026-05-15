defmodule Long.Agent.Browser.Installer do
  @moduledoc """
  Auto-installer for the Obscura headless-browser binary.

  Obscura ships as a single static binary in a per-platform tarball on
  GitHub Releases. On startup `Long.Agent.Browser.Engine` calls
  `ensure_installed/1` — if the binary is already on PATH or at the
  configured `:bin_dir`, we return its absolute path; otherwise we
  download the platform tarball, extract it, mark it executable, and
  return the new path.

  Designed to be called once at boot, ideally off the supervisor's
  critical path (via `handle_continue`) since the download is ~50 MB.

  ## Platform detection

  Maps `:os.type/0` + `:erlang.system_info(:system_architecture)` to one
  of the release asset names. Returns `{:error, {:unsupported_platform, …}}`
  when nothing matches (you'd fall back to manual install).
  """

  require Logger

  @release_base "https://github.com/h4ckf0r0day/obscura/releases/latest/download/"
  @default_bin_dir "priv/agent/bin"

  @doc """
  Resolve a usable `obscura` binary path, downloading on demand if
  necessary. Returns `{:ok, path}` or `{:error, reason}`.

  ## Options

    * `:bin_dir` — where to install (default `priv/agent/bin` relative
      to `File.cwd!/0`).
    * `:bin_name` — file name to look for / write (default `"obscura"`).
    * `:http` — Req-compatible request function (tests inject a stub).
    * `:force_download` — skip the "already installed?" check and
      always re-download.
  """
  @spec ensure_installed(keyword()) :: {:ok, String.t()} | {:error, term()}
  def ensure_installed(opts \\ []) do
    bin_dir = Keyword.get(opts, :bin_dir, default_bin_dir())
    bin_name = Keyword.get(opts, :bin_name, "obscura")
    force = Keyword.get(opts, :force_download, false)

    existing = if force, do: nil, else: locate(bin_name, bin_dir)

    cond do
      is_binary(existing) ->
        {:ok, existing}

      true ->
        with {:ok, asset} <- detect_asset(),
             {:ok, target} <- download_and_extract(asset, bin_dir, bin_name, opts) do
          {:ok, target}
        end
    end
  end

  @doc """
  Check well-known locations without downloading. Returns the path or
  `nil`. Useful for tests and for `Engine` to short-circuit when the
  binary is already there.
  """
  @spec locate(String.t(), String.t()) :: String.t() | nil
  def locate(bin_name \\ "obscura", bin_dir \\ default_bin_dir()) do
    cond do
      path = System.find_executable(bin_name) -> path
      File.exists?(Path.join(bin_dir, bin_name)) -> Path.join(bin_dir, bin_name) |> Path.expand()
      true -> nil
    end
  end

  @doc """
  Detect platform → release asset filename. Returns `{:ok, name}` where
  `name` is e.g. `"obscura-x86_64-linux.tar.gz"`, or
  `{:error, {:unsupported_platform, {os, arch}}}`.
  """
  @spec detect_asset() :: {:ok, String.t()} | {:error, term()}
  def detect_asset do
    os = detect_os()
    arch = detect_arch()

    case {os, arch} do
      {:linux, :x86_64} -> {:ok, "obscura-x86_64-linux.tar.gz"}
      {:macos, :x86_64} -> {:ok, "obscura-x86_64-macos.tar.gz"}
      {:macos, :aarch64} -> {:ok, "obscura-aarch64-macos.tar.gz"}
      {:windows, :x86_64} -> {:ok, "obscura-x86_64-windows.zip"}
      other -> {:error, {:unsupported_platform, other}}
    end
  end

  defp detect_os do
    case :os.type() do
      {:unix, :linux} -> :linux
      {:unix, :darwin} -> :macos
      {:win32, _} -> :windows
      other -> {:unknown, other}
    end
  end

  defp detect_arch do
    arch_str = :erlang.system_info(:system_architecture) |> to_string()

    cond do
      arch_str =~ ~r/aarch64|arm64/ -> :aarch64
      arch_str =~ ~r/x86_64|amd64/ -> :x86_64
      true -> {:unknown, arch_str}
    end
  end

  defp default_bin_dir do
    Application.app_dir(:long, @default_bin_dir)
  rescue
    _ -> Path.expand(@default_bin_dir, File.cwd!())
  end

  # ── Download + extract ───────────────────────────────────────────────

  defp download_and_extract(asset, bin_dir, bin_name, opts) do
    http = Keyword.get(opts, :http, &Req.request/1)
    url = @release_base <> asset
    File.mkdir_p!(bin_dir)
    tar_path = Path.join(bin_dir, asset)
    target_path = Path.join(bin_dir, bin_name)

    Logger.info("Browser.Installer: downloading Obscura from #{url} (~50MB, one-time)…")

    with {:ok, body} <- download(http, url),
         :ok <- File.write(tar_path, body),
         {:ok, _} <- extract(tar_path, bin_dir),
         {:ok, found} <- find_binary(bin_dir, bin_name),
         :ok <- maybe_move(found, target_path),
         :ok <- File.chmod(target_path, 0o755),
         :ok <- cleanup(tar_path) do
      Logger.info("Browser.Installer: Obscura installed at #{target_path}")
      {:ok, Path.expand(target_path)}
    else
      {:error, _} = err ->
        Logger.warning("Browser.Installer: install failed: #{inspect(err)}")
        err
    end
  end

  defp download(http, url) do
    case http.(
           method: :get,
           url: url,
           redirect: true,
           # Github CDN can be slow; allow up to 3 min for the 50 MB blob.
           receive_timeout: 180_000,
           retry: false,
           decode_body: false
         ) do
      {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) ->
        {:ok, body}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:http_status, status}}

      {:error, e} ->
        {:error, e}
    end
  end

  defp extract(tar_path, bin_dir) do
    cond do
      String.ends_with?(tar_path, ".tar.gz") ->
        case :erl_tar.extract(to_charlist(tar_path), [:compressed, {:cwd, to_charlist(bin_dir)}]) do
          :ok -> {:ok, bin_dir}
          err -> {:error, {:tar_extract, err}}
        end

      String.ends_with?(tar_path, ".zip") ->
        case :zip.unzip(to_charlist(tar_path), [{:cwd, to_charlist(bin_dir)}]) do
          {:ok, _} -> {:ok, bin_dir}
          err -> {:error, {:zip_extract, err}}
        end

      true ->
        {:error, {:unknown_archive, tar_path}}
    end
  end

  # Tarballs sometimes nest the binary in a subdirectory
  # (`obscura-x86_64-linux/obscura`). Glob for any matching file under
  # bin_dir, ignoring the archive itself.
  defp find_binary(bin_dir, bin_name) do
    Path.wildcard(Path.join(bin_dir, "**/#{bin_name}*"))
    |> Enum.reject(&String.ends_with?(&1, [".tar.gz", ".zip"]))
    |> Enum.filter(&File.regular?/1)
    |> case do
      [path | _] -> {:ok, path}
      [] -> {:error, :binary_not_found_in_archive}
    end
  end

  defp maybe_move(src, dest) do
    if Path.expand(src) == Path.expand(dest) do
      :ok
    else
      move_or_copy(src, dest)
    end
  end

  defp move_or_copy(src, dest) do
    # `File.rename` fails across mount points (EXDEV); fall back to copy+rm.
    case File.rename(src, dest) do
      :ok ->
        :ok

      {:error, _} ->
        with :ok <- File.cp(src, dest) do
          _ = File.rm(src)
          :ok
        end
    end
  end

  defp cleanup(tar_path) do
    _ = File.rm(tar_path)
    :ok
  end
end
