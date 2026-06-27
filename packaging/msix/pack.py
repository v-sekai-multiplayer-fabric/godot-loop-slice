#!/usr/bin/env python3
"""Create a signed MSIX package from an exported Godot Windows build.

Usage:
  pack.py --manifest packaging/msix/AppxManifest.xml \\
          --assets   packaging/msix/assets \\
          --bin-dir  build/windows \\
          --version  0.1.0.0 \\
          --out-dir  dist \\
          --name     v-sekai-loop-slice \\
          [--publisher "CN=v-sekai"] \\
          [--pfx-path cert.pfx --pfx-password pass] \\
          [--no-sign]

Requires: osslsigncode (for signing), openssl (for self-signed cert generation).
          Both available via: dnf install osslsigncode openssl
"""

import argparse
import base64
import hashlib
import re
import shutil
import subprocess
import sys
import zipfile
from pathlib import Path
from xml.etree import ElementTree as ET

BLOCK_SIZE = 65536

CONTENT_TYPES = {
    "exe": "application/octet-stream",
    "dll": "application/octet-stream",
    "pck": "application/octet-stream",
    "png": "image/png",
    "jpg": "image/jpeg",
    "jpeg": "image/jpeg",
    "svg": "image/svg+xml",
    "txt": "text/plain",
    "xml": "application/xml",
}


def sha256_blocks(path: Path) -> list[str]:
    blocks = []
    with open(path, "rb") as f:
        while chunk := f.read(BLOCK_SIZE):
            blocks.append(base64.b64encode(hashlib.sha256(chunk).digest()).decode())
    return blocks


def sha256_blocks_bytes(data: bytes) -> list[str]:
    return [
        base64.b64encode(hashlib.sha256(data[i : i + BLOCK_SIZE]).digest()).decode()
        for i in range(0, max(len(data), 1), BLOCK_SIZE)
    ]


def lfh_size(archive_name: str) -> int:
    """Local file header size in the ZIP: 30 fixed bytes + filename length (no extra field)."""
    return 30 + len(archive_name.encode("utf-8"))


def patch_manifest(src: Path, version: str, publisher: str) -> bytes:
    text = src.read_text(encoding="utf-8")
    # Replace only the first occurrence of each attribute (the Identity element)
    text = re.sub(r'Version="[^"]*"', f'Version="{version}"', text, count=1)
    text = re.sub(r'Publisher="[^"]*"', f'Publisher="{publisher}"', text, count=1)
    return text.encode("utf-8")


def build_content_types_xml(archive_names: list[str]) -> bytes:
    seen: set[str] = set()
    defaults = []
    for name in archive_names:
        ext = Path(name).suffix.lstrip(".").lower()
        if ext and ext not in seen:
            seen.add(ext)
            defaults.append((ext, CONTENT_TYPES.get(ext, "application/octet-stream")))

    root = ET.Element(
        "Types",
        xmlns="http://schemas.openxmlformats.org/package/2006/content-types",
    )
    for ext, ct in sorted(defaults):
        ET.SubElement(root, "Default", Extension=ext, ContentType=ct)
    ET.SubElement(
        root,
        "Override",
        PartName="/AppxManifest.xml",
        ContentType="application/vnd.ms-appx.manifest+xml",
    )
    ET.SubElement(
        root,
        "Override",
        PartName="/AppxBlockMap.xml",
        ContentType="application/vnd.ms-appx.blockmap+xml",
    )
    xml = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n' + ET.tostring(
        root, encoding="unicode"
    )
    return xml.encode("utf-8")


def build_block_map_xml(
    file_infos: list[tuple[str, int, int, list[str]]]
) -> bytes:
    root = ET.Element(
        "BlockMap",
        xmlns="http://schemas.microsoft.com/appx/2010/blockmap",
        HashMethod="http://www.w3.org/2001/04/xmlenc#sha256",
    )
    for bm_name, size, lfh, blocks in file_infos:
        fe = ET.SubElement(
            root, "File", Name=bm_name, Size=str(size), LfhSize=str(lfh)
        )
        for blk in blocks:
            ET.SubElement(fe, "Block", Hash=blk)
    xml = '<?xml version="1.0" encoding="UTF-8" standalone="no"?>\n' + ET.tostring(
        root, encoding="unicode"
    )
    return xml.encode("utf-8")


def write_stored(zf: zipfile.ZipFile, archive_name: str, data: bytes) -> None:
    zi = zipfile.ZipInfo(archive_name)
    zi.compress_type = zipfile.ZIP_STORED
    zi.extra = b""
    zf.writestr(zi, data)


def write_stored_file(zf: zipfile.ZipFile, archive_name: str, src: Path) -> None:
    zi = zipfile.ZipInfo(archive_name)
    zi.compress_type = zipfile.ZIP_STORED
    zi.extra = b""
    with zf.open(zi, "w") as dst, open(src, "rb") as src_f:
        shutil.copyfileobj(src_f, dst)


def pack_msix(
    manifest_path: Path,
    assets_dir: Path,
    bin_dir: Path,
    version: str,
    publisher: str,
    out_path: Path,
) -> None:
    manifest_data = patch_manifest(manifest_path, version, publisher)

    bin_files = sorted(p for p in bin_dir.iterdir() if p.is_file())
    asset_files = sorted(p for p in assets_dir.iterdir() if p.is_file())

    # Content entries in ZIP order (after [Content_Types].xml and AppxBlockMap.xml)
    # list of (archive_name, src_path_or_None, inline_data_or_None)
    entries: list[tuple[str, Path | None, bytes | None]] = []
    entries.append(("AppxManifest.xml", None, manifest_data))
    for p in bin_files:
        entries.append((f"bin/{p.name}", p, None))
    for p in asset_files:
        entries.append((f"assets/{p.name}", p, None))

    # Compute block map info (all entries go into the block map)
    block_map_infos: list[tuple[str, int, int, list[str]]] = []
    archive_names: list[str] = []
    for archive_name, src, inline in entries:
        archive_names.append(archive_name)
        if inline is not None:
            blocks = sha256_blocks_bytes(inline)
            size = len(inline)
        else:
            blocks = sha256_blocks(src)
            size = src.stat().st_size
        block_map_infos.append(
            (archive_name.replace("/", "\\"), size, lfh_size(archive_name), blocks)
        )

    content_types_data = build_content_types_xml(archive_names)
    block_map_data = build_block_map_xml(block_map_infos)

    out_path.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(out_path, "w", allowZip64=False) as zf:
        # [Content_Types].xml and AppxBlockMap.xml must come first
        write_stored(zf, "[Content_Types].xml", content_types_data)
        write_stored(zf, "AppxBlockMap.xml", block_map_data)
        for archive_name, src, inline in entries:
            if inline is not None:
                write_stored(zf, archive_name, inline)
            else:
                write_stored_file(zf, archive_name, src)

    print(f"Packed: {out_path}")


def sign_msix(
    msix_path: Path,
    pfx_path: Path | None,
    pfx_password: str | None,
    publisher: str,
    out_dir: Path,
) -> None:
    if pfx_path is None:
        cn = re.sub(r"^CN=", "", publisher)
        key_pem = out_dir / "loop-test-key.pem"
        cert_pem = out_dir / "loop-test-cert.pem"
        pfx_path = out_dir / "loop-test.pfx"
        pfx_password = "test"
        subprocess.run(
            [
                "openssl", "req", "-x509", "-newkey", "rsa:2048",
                "-keyout", str(key_pem), "-out", str(cert_pem),
                "-days", "365", "-nodes",
                "-subj", f"/CN={cn}",
                "-addext", "extendedKeyUsage=codeSigning",
            ],
            check=True,
            capture_output=True,
        )
        subprocess.run(
            [
                "openssl", "pkcs12", "-export",
                "-out", str(pfx_path),
                "-inkey", str(key_pem),
                "-in", str(cert_pem),
                "-passout", f"pass:{pfx_password}",
            ],
            check=True,
            capture_output=True,
        )
        print(f"Generated self-signed test cert: {pfx_path}")

    signed = msix_path.with_suffix(".signed.msix")
    result = subprocess.run(
        [
            "osslsigncode", "sign",
            "-pkcs12", str(pfx_path),
            "-pass", pfx_password or "",
            "-in", str(msix_path),
            "-out", str(signed),
        ],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        print(result.stderr, file=sys.stderr)
        raise RuntimeError(f"osslsigncode failed (exit {result.returncode})")
    signed.replace(msix_path)
    print(f"Signed:  {msix_path}")


def main() -> None:
    ap = argparse.ArgumentParser(description="Pack an MSIX from a Godot Windows export")
    ap.add_argument("--manifest", required=True, help="Path to AppxManifest.xml")
    ap.add_argument("--assets", required=True, help="Path to assets/ directory")
    ap.add_argument("--bin-dir", required=True, help="Directory with exported game binary")
    ap.add_argument("--version", default="0.1.0.0", help="4-part version (e.g. 0.1.0.0)")
    ap.add_argument("--out-dir", default="dist", help="Output directory")
    ap.add_argument("--name", required=True, help="Output base name (e.g. v-sekai-loop-slice)")
    ap.add_argument("--publisher", default="CN=v-sekai", help="Publisher CN string")
    ap.add_argument("--pfx-path", help="Path to signing PFX (omit for self-signed test cert)")
    ap.add_argument("--pfx-password", help="PFX password")
    ap.add_argument("--no-sign", action="store_true", help="Skip signing step")
    args = ap.parse_args()

    out_dir = Path(args.out_dir)
    out_path = out_dir / f"{args.name}-{args.version}.msix"

    pack_msix(
        Path(args.manifest),
        Path(args.assets),
        Path(args.bin_dir),
        args.version,
        args.publisher,
        out_path,
    )

    if not args.no_sign:
        sign_msix(
            out_path,
            Path(args.pfx_path) if args.pfx_path else None,
            args.pfx_password,
            args.publisher,
            out_dir,
        )


if __name__ == "__main__":
    main()
