#!/usr/bin/env python3
"""Build the loop-slice client + server MSIX packages, end to end.

Cross-platform orchestrator (Python 3 standard library only -- no pip installs):
it downloads the merged "double" Godot editor + Windows export template from the
v-sekai-multiplayer-fabric/godot-images release, exports the Windows builds, then
packs + self-signs both MSIX with the existing PowerShell packers
(packaging/msix/pack.ps1, packaging/msix-server/pack-server.ps1).

The MSIX pack/sign stage needs the Windows SDK (makeappx.exe + signtool.exe), so the
full build completes only on Windows or on WSL (which reaches the Windows SDK + the
Windows editor through interop). On a bare Linux/macOS host the script downloads and
reports clearly that it cannot finish -- this release ships Windows binaries only and
MSIX is a Windows artifact. Mirrors .github/workflows/release-msix.yml.

  python3 packaging/build_msix.py [--tag TAG] [--version A.B.C.D] [--stage DIR]
                                  [--skip-server] [--pfx PATH --pfx-pass PW] [--force]
"""
from __future__ import annotations

import argparse
import os
import platform
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.request
import zipfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent  # packaging/ -> repo root
# NB: the "latest" tag (v2026.06.27.1752-multiplayer-fabric) ships an INCOMPLETE
# windows-editor.zip (~74 MB: only the D3D12/mesa driver DLLs, no Godot binary).
# 0.1.0-dev.8 carries the real Windows editor (~482 MB) + template (~345 MB).
DEFAULT_TAG = "0.1.0-dev.8"
DEFAULT_VERSION = "0.1.0.1"
RELEASE_BASE = (
    "https://github.com/v-sekai-multiplayer-fabric/godot-images/releases/download"
)
EDITOR_ASSET = "windows-editor.zip"
TEMPLATE_ASSET = "windows-template-release.zip"


# --------------------------------------------------------------------------- #
# host detection + path helpers
# --------------------------------------------------------------------------- #
def is_wsl() -> bool:
    if platform.system() != "Linux":
        return False
    try:
        return "microsoft" in Path("/proc/version").read_text().lower()
    except OSError:
        return False


HOST = platform.system()  # 'Windows' | 'Linux' | 'Darwin'
WSL = is_wsl()
# A Windows SDK is reachable for the pack stage from native Windows or from WSL.
CAN_PACK = HOST == "Windows" or WSL


def run(cmd, **kw):
    """subprocess.run wrapper that echoes the command."""
    printable = cmd if isinstance(cmd, str) else " ".join(str(c) for c in cmd)
    print(f"  $ {printable}", flush=True)
    return subprocess.run(cmd, **kw)


def to_win(path: Path) -> str:
    """A native Windows path string for `path`, for the Windows editor / SDK tools."""
    path = Path(path)
    if WSL:
        out = subprocess.run(
            ["wslpath", "-w", str(path)], capture_output=True, text=True, check=True
        )
        return out.stdout.strip()
    return str(path)


def win_userprofile_as_local() -> Path | None:
    """The Windows %USERPROFILE% as a path this host can write to (WSL only)."""
    if not WSL:
        return None
    try:
        # run from /mnt/c so cmd.exe doesn't warn about a UNC working directory
        out = subprocess.run(
            ["cmd.exe", "/c", "echo %USERPROFILE%"],
            capture_output=True, text=True, cwd="/mnt/c", check=True,
        )
        win = out.stdout.strip()
        if not win or win.startswith("%"):
            return None
        back = subprocess.run(
            ["wslpath", "-u", win], capture_output=True, text=True, check=True
        )
        return Path(back.stdout.strip())
    except (OSError, subprocess.CalledProcessError):
        return None


def default_stage() -> Path:
    """Stage on a Windows-native filesystem so the editor/SDK get plain C:\\ paths."""
    if HOST == "Windows":
        return Path(os.environ.get("USERPROFILE", os.getcwd())) / "loop-build"
    prof = win_userprofile_as_local()
    if prof is not None:
        return prof / "loop-build"
    if WSL:
        return Path("/mnt/c/loop-build")
    return Path(tempfile.gettempdir()) / "loop-build"


def powershell() -> str | None:
    for exe in ("powershell.exe", "pwsh", "pwsh.exe"):
        if shutil.which(exe):
            return exe
    return None


# --------------------------------------------------------------------------- #
# stages
# --------------------------------------------------------------------------- #
def download(url: str, dest: Path, force: bool) -> None:
    if dest.exists() and dest.stat().st_size > 0 and not force:
        print(f"  have {dest.name} ({dest.stat().st_size:,} B) -- skip download")
        return
    print(f"  downloading {url}")
    tmp = dest.with_suffix(dest.suffix + ".part")
    with urllib.request.urlopen(url) as r, open(tmp, "wb") as f:  # noqa: S310 (trusted host)
        shutil.copyfileobj(r, f)
    tmp.replace(dest)
    print(f"  -> {dest} ({dest.stat().st_size:,} B)")


def unzip(zip_path: Path, out_dir: Path) -> None:
    out_dir.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(zip_path) as z:
        z.extractall(out_dir)


def find_exe(root: Path, must_have: str = "", prefer: str = "") -> Path:
    """Pick an .exe under `root`: skip console wrappers, prefer a name hint, else biggest."""
    exes = [p for p in root.rglob("*.exe") if not p.name.lower().endswith(".console.exe")]
    if must_have:
        exes = [p for p in exes if must_have.lower() in p.name.lower()] or exes
    if not exes:
        raise SystemExit(f"no .exe found under {root}")
    if prefer:
        for p in exes:
            if prefer.lower() in p.name.lower():
                return p
    return max(exes, key=lambda p: p.stat().st_size)


def patch_presets(presets: Path, template_win: str, indices=(2, 3)) -> None:
    """Set custom_template/release for the given preset indices (staged copy only)."""
    lines = presets.read_text().splitlines()
    cur = None
    esc = template_win.replace("\\", "\\\\")  # cfg strings keep literal backslashes
    out = []
    for line in lines:
        m = re.match(r"^\[preset\.(\d+)\.options\]", line)
        if m:
            cur = int(m.group(1))
        if cur in indices and line.startswith("custom_template/release="):
            line = f'custom_template/release="{esc}"'
        out.append(line)
    presets.write_text("\n".join(out) + "\n")
    print(f"  patched {presets.name}: presets {indices} release template -> {template_win}")


def export(editor: Path, project: Path, preset: str, out_rel: str) -> Path:
    out = project / out_rel
    out.parent.mkdir(parents=True, exist_ok=True)
    run([str(editor), "--headless", "--export-release", preset, out_rel],
        cwd=str(project))
    if not out.exists() or out.stat().st_size < 1_000_000:
        size = out.stat().st_size if out.exists() else 0
        raise SystemExit(f"export '{preset}' produced no usable exe ({out}, {size} B)")
    print(f"  exported {preset}: {out} ({out.stat().st_size:,} B)")
    return out


def pack(ps: str, script: Path, bindir: Path, version: str, outdir: Path,
         project: Path, pfx: str | None, pfx_pass: str | None) -> None:
    args = [ps, "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", to_win(script),
            "-BinDir", to_win(bindir), "-Version", version, "-OutDir", to_win(outdir)]
    if pfx:
        args += ["-PfxPath", to_win(Path(pfx))]
        if pfx_pass:
            args += ["-PfxPassword", pfx_pass]
    res = run(args, cwd=str(project))
    if res.returncode != 0:
        raise SystemExit(f"{script.name} failed ({res.returncode})")


# --------------------------------------------------------------------------- #
def main() -> int:
    ap = argparse.ArgumentParser(description="Build loop-slice client+server MSIX.")
    ap.add_argument("--tag", default=DEFAULT_TAG, help="godot-images release tag")
    ap.add_argument("--version", default=DEFAULT_VERSION, help="4-part package version")
    ap.add_argument("--stage", default=None, help="staging dir (default: Windows-native)")
    ap.add_argument("--skip-server", action="store_true", help="client MSIX only")
    ap.add_argument("--pfx", default=None, help="signing .pfx (default: self-signed TEST)")
    ap.add_argument("--pfx-pass", default=None, help=".pfx password")
    ap.add_argument("--force", action="store_true", help="re-download assets")
    a = ap.parse_args()

    stage = Path(a.stage) if a.stage else default_stage()
    print(f"host={HOST} wsl={WSL} can_pack={CAN_PACK}")
    print(f"tag={a.tag} version={a.version}")
    print(f"stage={stage}")

    # cache assets per tag so switching --tag never collides on a shared filename
    dl = stage / "dl" / a.tag
    tools, templates, project = dl / "editor", dl / "template", stage / "project"
    dist = project / "dist"
    for d in (dl, tools, templates, project):
        d.mkdir(parents=True, exist_ok=True)

    # 1. download + unzip engine assets, discover exe names ------------------ #
    print("\n[1/5] fetch + unzip godot-images assets")
    editor_zip, template_zip = dl / EDITOR_ASSET, dl / TEMPLATE_ASSET
    download(f"{RELEASE_BASE}/{a.tag}/{EDITOR_ASSET}", editor_zip, a.force)
    download(f"{RELEASE_BASE}/{a.tag}/{TEMPLATE_ASSET}", template_zip, a.force)
    unzip(editor_zip, tools)
    unzip(template_zip, templates)
    editor = find_exe(tools, must_have="windows", prefer="editor")
    template = find_exe(templates, must_have="windows", prefer="template")
    print(f"  editor   = {editor.name}")
    print(f"  template = {template.name}")

    # 2. stage project copy -------------------------------------------------- #
    print("\n[2/5] stage project")
    shutil.copytree(
        REPO, project, dirs_exist_ok=True,
        ignore=shutil.ignore_patterns(".git", "build", ".godot", "run", "dist", "*.db"),
    )
    print(f"  copied repo -> {project}")

    # 3. patch staged export presets ----------------------------------------- #
    print("\n[3/5] patch export presets")
    patch_presets(project / "export_presets.cfg", to_win(template))

    if not CAN_PACK:
        print("\nNOTE: no Windows SDK reachable on this host -- exporting only.")
        print("      MSIX pack/sign needs makeappx+signtool (Windows/WSL).")

    # 4. export Windows builds ---------------------------------------------- #
    print("\n[4/5] export Windows builds (headless)")
    run([str(editor), "--headless", "--import", "."], cwd=str(project))  # tolerate rc!=0
    client_bin = export(editor, project, "Windows Desktop", "build/windows/loop-slice.exe")
    if not a.skip_server:
        export(editor, project, "Windows Dedicated Server",
               "build/windows-server/loop-slice-server.exe")

    if not CAN_PACK:
        print(f"\nDONE (exports only). exe at: {client_bin}")
        return 0

    # 5. pack + sign MSIX ---------------------------------------------------- #
    print("\n[5/5] pack + sign MSIX")
    ps = powershell()
    if not ps:
        raise SystemExit("no PowerShell (powershell.exe / pwsh) found for the pack stage")
    dist.mkdir(parents=True, exist_ok=True)
    pack(ps, project / "packaging" / "msix" / "pack.ps1",
         project / "build" / "windows", a.version, dist, project, a.pfx, a.pfx_pass)
    if not a.skip_server:
        pack(ps, project / "packaging" / "msix-server" / "pack-server.ps1",
             project / "build" / "windows-server", a.version, dist, project,
             a.pfx, a.pfx_pass)

    print("\nDONE. MSIX outputs:")
    for m in sorted(dist.glob("*.msix")):
        print(f"  {m}  ({m.stat().st_size:,} B)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
