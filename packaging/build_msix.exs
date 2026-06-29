#!/usr/bin/env elixir
# Build the loop-slice client + server MSIX packages, end to end.
#
# Elixir port of the former build_msix.py. Run with `elixir packaging/build_msix.exs`.
# It downloads the merged "double" Godot editor + Windows template from the
# godot-images release, stages the project, exports both Windows builds headless,
# then packs + self-signs the MSIX with the existing pack.ps1 / pack-server.ps1.
#
# The pack/sign stage needs the Windows SDK (makeappx + signtool), which is only
# reachable on native Windows or on WSL (via Windows interop) -- the build
# requires one of those.
#
#   elixir packaging/build_msix.exs [--tag TAG] [--version A.B.C.D] [--stage DIR]
#                                   [--skip-server] [--pfx PATH --pfx-pass PW] [--force]

defmodule BuildMsix do
  @repo Path.expand("..", __DIR__)
  @default_tag "0.1.0-dev.8"
  @default_version "0.1.0.1"
  @release_base "https://github.com/v-sekai-multiplayer-fabric/godot-images/releases/download"
  @editor_asset "windows-editor.zip"
  @template_asset "windows-template-release.zip"

  # ── host detection ──────────────────────────────────────────────────────
  def windows?, do: match?({:win32, _}, :os.type())

  def wsl? do
    match?({:ok, v} when is_binary(v), File.read("/proc/version")) and
      File.read!("/proc/version") |> String.downcase() |> String.contains?("microsoft")
  end

  # ── shell helpers ───────────────────────────────────────────────────────
  # Stream output to the console; return the exit status.
  def run(cmd, args, opts \\ []) do
    IO.puts("  $ #{cmd} #{Enum.join(args, " ")}")
    {_, status} =
      System.cmd(cmd, args, [into: IO.stream(:stdio, :line), stderr_to_stdout: true] ++ opts)

    status
  end

  def run!(cmd, args, opts \\ []) do
    case run(cmd, args, opts) do
      0 -> :ok
      n -> die("`#{cmd}` exited with #{n}")
    end
  end

  # Capture stdout as a trimmed string.
  def cmd_out(cmd, args, opts \\ []) do
    {out, _} = System.cmd(cmd, args, opts)
    String.trim(out)
  end

  def die(msg) do
    IO.puts(:stderr, "ERROR: #{msg}")
    System.halt(1)
  end

  # ── path helpers ────────────────────────────────────────────────────────
  # A native Windows path string for the Windows editor / SDK tools.
  def to_win(path) do
    if wsl?(), do: cmd_out("wslpath", ["-w", to_string(path)]), else: to_string(path)
  end

  # Windows %USERPROFILE% as a path this host can write to (WSL only).
  def win_userprofile_local do
    win = cmd_out("cmd.exe", ["/c", "echo %USERPROFILE%"], cd: "/mnt/c")

    if win == "" or String.starts_with?(win, "%") do
      nil
    else
      cmd_out("wslpath", ["-u", win])
    end
  rescue
    _ -> nil
  end

  # Stage on a Windows-native filesystem so the editor/SDK get plain C:\ paths.
  def default_stage do
    if windows?() do
      Path.join(System.get_env("USERPROFILE", File.cwd!()), "loop-build")
    else
      case win_userprofile_local() do
        nil -> "/mnt/c/loop-build"
        prof -> Path.join(prof, "loop-build")
      end
    end
  end

  def powershell do
    Enum.find_value(["powershell.exe", "pwsh", "pwsh.exe"], &System.find_executable/1)
  end

  # ── stages ──────────────────────────────────────────────────────────────
  def download(url, dest, force) do
    if File.exists?(dest) and File.stat!(dest).size > 0 and not force do
      IO.puts("  have #{Path.basename(dest)} (#{File.stat!(dest).size} B) -- skip download")
    else
      IO.puts("  downloading #{url}")
      tmp = dest <> ".part"
      if run("curl", ["-fL", "--retry", "3", url, "-o", tmp]) != 0, do: die("download failed: #{url}")
      File.rename!(tmp, dest)
      IO.puts("  -> #{dest} (#{File.stat!(dest).size} B)")
    end
  end

  def unzip(zip, out_dir) do
    File.mkdir_p!(out_dir)

    case :zip.extract(String.to_charlist(zip), cwd: String.to_charlist(out_dir)) do
      {:ok, _} -> :ok
      {:error, reason} -> die("unzip #{zip} failed: #{inspect(reason)}")
    end
  end

  # Pick an .exe under root: skip console wrappers, prefer a name hint, else biggest.
  # Name matching is on the basename only -- the extraction dir itself is named
  # "windows-editor-<hash>", so matching the full path would catch every file.
  def find_exe(root, must_have \\ "", prefer \\ "") do
    base = fn p -> p |> Path.basename() |> String.downcase() end

    exes =
      Path.wildcard(Path.join(root, "**/*.exe"))
      |> Enum.reject(&String.ends_with?(base.(&1), ".console.exe"))

    exes =
      if must_have != "" do
        case Enum.filter(exes, &String.contains?(base.(&1), String.downcase(must_have))) do
          [] -> exes
          hit -> hit
        end
      else
        exes
      end

    if exes == [], do: die("no .exe found under #{root}")

    cond do
      prefer != "" and Enum.any?(exes, &String.contains?(base.(&1), String.downcase(prefer))) ->
        Enum.find(exes, &String.contains?(base.(&1), String.downcase(prefer)))

      true ->
        Enum.max_by(exes, &File.stat!(&1).size)
    end
  end

  # Set custom_template/release for the given preset indices (staged copy only).
  def patch_presets(presets, template_win, indices \\ [2, 3]) do
    # cfg strings keep literal backslashes -> double them
    esc = String.replace(template_win, "\\", "\\\\")

    {lines, _} =
      presets
      |> File.read!()
      |> String.split("\n")
      |> Enum.map_reduce(nil, fn line, cur ->
        cur =
          case Regex.run(~r/^\[preset\.(\d+)\.options\]/, line) do
            [_, n] -> String.to_integer(n)
            nil -> cur
          end

        line =
          if cur in indices and String.starts_with?(line, "custom_template/release=") do
            ~s(custom_template/release="#{esc}")
          else
            line
          end

        {line, cur}
      end)

    File.write!(presets, Enum.join(lines, "\n"))
    IO.puts("  patched #{Path.basename(presets)}: presets #{inspect(indices)} -> #{template_win}")
  end

  # Recursive project copy excluding build artifacts (no shell deps).
  def stage_copy(src, dst) do
    excl = ~w(.git build .godot run dist)
    File.mkdir_p!(dst)

    for name <- File.ls!(src), name not in excl, not String.ends_with?(name, ".db") do
      s = Path.join(src, name)
      d = Path.join(dst, name)
      if File.dir?(s), do: stage_copy(s, d), else: File.cp!(s, d)
    end
  end

  def export(editor, project, preset, out_rel) do
    out = Path.join(project, out_rel)
    File.mkdir_p!(Path.dirname(out))
    run!(to_string(editor), ["--headless", "--export-release", preset, out_rel], cd: project)
    size = if File.exists?(out), do: File.stat!(out).size, else: 0
    if size < 1_000_000, do: die("export '#{preset}' produced no usable exe (#{out}, #{size} B)")
    IO.puts("  exported #{preset}: #{out} (#{size} B)")
    out
  end

  def pack(ps, script, bindir, version, outdir, project, pfx, pfx_pass) do
    args =
      [ps, "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", to_win(script),
       "-BinDir", to_win(bindir), "-Version", version, "-OutDir", to_win(outdir)]

    args = if pfx, do: args ++ ["-PfxPath", to_win(pfx)], else: args
    args = if pfx && pfx_pass, do: args ++ ["-PfxPassword", pfx_pass], else: args
    [cmd | rest] = args
    run!(cmd, rest, cd: project)
  end

  # ── main ────────────────────────────────────────────────────────────────
  def main(argv) do
    unless windows?() or wsl?() do
      die("MSIX build requires Windows or WSL -- makeappx/signtool are Windows-only")
    end

    {o, _, _} =
      OptionParser.parse(argv,
        strict: [tag: :string, version: :string, stage: :string, skip_server: :boolean,
                 exe_only: :boolean, pfx: :string, pfx_pass: :string, force: :boolean]
      )

    tag = o[:tag] || @default_tag
    version = o[:version] || @default_version
    stage = o[:stage] || default_stage()
    force = o[:force] || false
    skip_server = o[:skip_server] || false
    exe_only = o[:exe_only] || false
    pfx = o[:pfx]
    pfx_pass = o[:pfx_pass]

    IO.puts("windows=#{windows?()} wsl=#{wsl?()}")
    IO.puts("tag=#{tag} version=#{version}")
    IO.puts("stage=#{stage}")

    # cache assets per tag so switching --tag never collides on a shared filename
    dl = Path.join([stage, "dl", tag])
    tools = Path.join(dl, "editor")
    templates = Path.join(dl, "template")
    project = Path.join(stage, "project")
    dist = Path.join(project, "dist")
    Enum.each([dl, tools, templates, project], &File.mkdir_p!/1)

    IO.puts("\n[1/5] fetch + unzip godot-images assets")
    editor_zip = Path.join(dl, @editor_asset)
    template_zip = Path.join(dl, @template_asset)
    download("#{@release_base}/#{tag}/#{@editor_asset}", editor_zip, force)
    download("#{@release_base}/#{tag}/#{@template_asset}", template_zip, force)
    unzip(editor_zip, tools)
    unzip(template_zip, templates)
    editor = find_exe(tools, "windows", "editor")
    template = find_exe(templates, "windows", "template")
    IO.puts("  editor   = #{Path.basename(editor)}")
    IO.puts("  template = #{Path.basename(template)}")

    IO.puts("\n[2/5] stage project")
    stage_copy(@repo, project)
    IO.puts("  copied repo -> #{project}")

    IO.puts("\n[3/5] patch export presets")
    patch_presets(Path.join(project, "export_presets.cfg"), to_win(template))

    IO.puts("\n[4/5] export Windows builds (headless)")
    run(to_string(editor), ["--headless", "--import", "."], cd: project)
    client_exe = export(editor, project, "Windows Desktop", "build/windows/loop-slice.exe")

    server_exe =
      unless skip_server do
        export(editor, project, "Windows Dedicated Server", "build/windows-server/loop-slice-server.exe")
      end

    if exe_only do
      # Plain-download demo path: stop after the exes -- no Windows SDK, no cert.
      IO.puts("\nDONE (exe-only). Windows builds:")
      for exe <- Enum.reject([client_exe, server_exe], &is_nil/1) do
        IO.puts("  #{exe}  (#{File.stat!(exe).size} B)")
      end
    else
      IO.puts("\n[5/5] pack + sign MSIX")
      ps = powershell() || die("no PowerShell (powershell.exe / pwsh) for the pack stage")
      File.mkdir_p!(dist)

      pack(ps, Path.join([project, "packaging", "msix", "pack.ps1"]),
        Path.join([project, "build", "windows"]), version, dist, project, pfx, pfx_pass)

      unless skip_server do
        pack(ps, Path.join([project, "packaging", "msix-server", "pack-server.ps1"]),
          Path.join([project, "build", "windows-server"]), version, dist, project, pfx, pfx_pass)
      end

      IO.puts("\nDONE. MSIX outputs:")
      for m <- Path.wildcard(Path.join(dist, "*.msix")) |> Enum.sort() do
        IO.puts("  #{m}  (#{File.stat!(m).size} B)")
      end
    end
  end
end

BuildMsix.main(System.argv())
