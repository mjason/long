defmodule Long.Agent.Deno.Installer do
  @moduledoc """
  Auto-installer for the Deno runtime binary.

  Deno ships as a single self-contained binary inside a per-platform
  `.zip` on GitHub Releases. On startup `Long.Agent.Deno.Engine` calls
  `ensure_installed/1` — if `deno` is already on PATH or at the configured
  `:bin_dir`, we return its absolute path; otherwise we download the
  platform zip, extract it, mark it executable, and return the new path.

  This keeps the deployment self-contained — the whole reason code
  execution runs on Deno — so the host doesn't need a manual install.

  Mirrors `Long.Agent.Browser.Installer`. Designed to be called once at
  boot off the supervisor's critical path (the download is ~40 MB).

  ## Platform detection

  Maps `:os.type/0` + `:erlang.system_info(:system_architecture)` to a
  Deno release asset (a Rust target triple). Returns
  `{:error, {:unsupported_platform, …}}` when nothing matches.
  """

  require Logger

  @release_base "https://github.com/denoland/deno/releases/latest/download/"
  @default_bin_dir "priv/agent/bin"

  @doc """
  Resolve a usable `deno` binary path, downloading on demand. Returns
  `{:ok, path}` or `{:error, reason}`.

  ## Options

    * `:bin_dir` — where to install (default `priv/agent/bin`).
    * `:bin_name` — file to look for / write (default `"deno"` /
      `"deno.exe"` on Windows).
    * `:http` — Req-compatible request function (tests inject a stub).
    * `:force_download` — always re-download.
  """
  @spec ensure_installed(keyword()) :: {:ok, String.t()} | {:error, term()}
  def ensure_installed(opts \\ []) do
    bin_dir = Keyword.get(opts, :bin_dir, default_bin_dir())
    bin_name = Keyword.get(opts, :bin_name, default_bin_name())
    force = Keyword.get(opts, :force_download, false)

    existing = if force, do: nil, else: locate(bin_name, bin_dir)

    if is_binary(existing) do
      {:ok, existing}
    else
      with {:ok, asset} <- detect_asset(),
           {:ok, target} <- download_and_extract(asset, bin_dir, bin_name, opts) do
        {:ok, target}
      end
    end
  end

  @doc "Find `deno` on PATH or in `bin_dir` without downloading. Returns the path or `nil`."
  @spec locate(String.t(), String.t()) :: String.t() | nil
  def locate(bin_name \\ default_bin_name(), bin_dir \\ default_bin_dir()) do
    cond do
      path = System.find_executable(bin_name) -> path
      File.exists?(Path.join(bin_dir, bin_name)) -> Path.expand(Path.join(bin_dir, bin_name))
      true -> nil
    end
  end

  @doc """
  Detect platform → Deno release asset filename, e.g.
  `"deno-x86_64-unknown-linux-gnu.zip"`, or
  `{:error, {:unsupported_platform, {os, arch}}}`.
  """
  @spec detect_asset() :: {:ok, String.t()} | {:error, term()}
  def detect_asset do
    case {detect_os(), detect_arch()} do
      {:linux, :x86_64} -> {:ok, "deno-x86_64-unknown-linux-gnu.zip"}
      {:linux, :aarch64} -> {:ok, "deno-aarch64-unknown-linux-gnu.zip"}
      {:macos, :x86_64} -> {:ok, "deno-x86_64-apple-darwin.zip"}
      {:macos, :aarch64} -> {:ok, "deno-aarch64-apple-darwin.zip"}
      {:windows, :x86_64} -> {:ok, "deno-x86_64-pc-windows-msvc.zip"}
      other -> {:error, {:unsupported_platform, other}}
    end
  end

  @doc "Binary file name for the current OS (`deno` / `deno.exe`)."
  def default_bin_name do
    case :os.type() do
      {:win32, _} -> "deno.exe"
      _ -> "deno"
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
    url = Keyword.get(opts, :release_base, @release_base) <> asset
    File.mkdir_p!(bin_dir)
    zip_path = Path.join(bin_dir, asset)
    target_path = Path.join(bin_dir, bin_name)

    Logger.info("Deno.Installer: downloading Deno from #{url} (~40MB, one-time)…")

    with {:ok, body} <- download(http, url),
         :ok <- File.write(zip_path, body),
         {:ok, _} <- extract(zip_path, bin_dir),
         {:ok, found} <- find_binary(bin_dir, bin_name),
         :ok <- maybe_move(found, target_path),
         :ok <- File.chmod(target_path, 0o755),
         :ok <- cleanup(zip_path) do
      Logger.info("Deno.Installer: Deno installed at #{target_path}")
      {:ok, Path.expand(target_path)}
    else
      {:error, _} = err ->
        Logger.warning("Deno.Installer: install failed: #{inspect(err)}")
        err
    end
  end

  defp download(http, url) do
    case http.(
           method: :get,
           url: url,
           redirect: true,
           receive_timeout: 180_000,
           retry: false,
           decode_body: false
         ) do
      {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) -> {:ok, body}
      {:ok, %Req.Response{status: status}} -> {:error, {:http_status, status}}
      {:error, e} -> {:error, e}
    end
  end

  defp extract(zip_path, bin_dir) do
    case :zip.unzip(to_charlist(zip_path), [{:cwd, to_charlist(bin_dir)}]) do
      {:ok, _} -> {:ok, bin_dir}
      err -> {:error, {:zip_extract, err}}
    end
  end

  defp find_binary(bin_dir, bin_name) do
    Path.wildcard(Path.join(bin_dir, "**/#{bin_name}"))
    |> Enum.filter(&File.regular?/1)
    |> case do
      [path | _] -> {:ok, path}
      [] -> {:error, :binary_not_found_in_archive}
    end
  end

  defp maybe_move(src, dest) do
    if Path.expand(src) == Path.expand(dest), do: :ok, else: move_or_copy(src, dest)
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

  defp cleanup(zip_path) do
    _ = File.rm(zip_path)
    :ok
  end
end
