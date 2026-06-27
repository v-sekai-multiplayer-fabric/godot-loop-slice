# Local MSIX build pipeline for v-sekai/loop-slice.
# Requires: just, python3, osslsigncode, openssl, curl
#
# Quick start:
#   just install-packages          # install osslsigncode + openssl (Fedora/RHEL)
#   just fetch-windows-template    # download Windows Godot template from godot-images release
#   just build-msix                # export game + pack + sign MSIX
#   just install-msix-service      # install systemd oneshot for hands-free rebuilds

export WORLD_PWD          := invocation_directory()
export GODOT_IMAGES_DIR   := env_var_or_default("GODOT_IMAGES_DIR", WORLD_PWD + "/../godot-images")
export GODOT_EDITOR       := env_var_or_default("GODOT_EDITOR", "")
export MSIX_VERSION       := env_var_or_default("MSIX_VERSION", "0.1.0.0")
export MSIX_PUBLISHER     := env_var_or_default("MSIX_PUBLISHER", "CN=v-sekai")
export PFX_PATH           := env_var_or_default("PFX_PATH", "")
export PFX_PASSWORD       := env_var_or_default("PFX_PASSWORD", "")
export GODOT_IMAGES_REPO  := "v-sekai-multiplayer-fabric/godot-images"
# A 6-asset release that ships the real windows-template-release.zip (the "latest"
# tag is incomplete). Override with GODOT_IMAGES_TAG=... when a newer one lands.
export GODOT_IMAGES_TAG   := env_var_or_default("GODOT_IMAGES_TAG", "0.1.0-dev.8")

# ── Tool setup ───────────────────────────────────────────────────────────

install-packages:
    #!/usr/bin/env bash
    if command -v dnf &>/dev/null; then
        sudo dnf install -y osslsigncode openssl
    elif command -v apt-get &>/dev/null; then
        sudo apt-get install -y osslsigncode openssl
    else
        echo "Unsupported package manager — install osslsigncode and openssl manually" >&2
        exit 1
    fi

# ── Godot tools ─────────────────────────────────────────────────────────

# Print path to the best available Linux double-precision Godot editor.
# Order: $GODOT_EDITOR env, local build in godot-images/editors, local godot/bin.
_find-editor:
    #!/usr/bin/env bash
    set -euo pipefail
    if [ -n "${GODOT_EDITOR}" ]; then echo "${GODOT_EDITOR}"; exit 0; fi
    for candidate in \
        "${GODOT_IMAGES_DIR}/editors/godot.linuxbsd.editor.double.x86_64" \
        "${GODOT_IMAGES_DIR}/../godot/bin/godot.linuxbsd.editor.double.x86_64"; do
        if [ -x "$candidate" ]; then echo "$candidate"; exit 0; fi
    done
    echo "ERROR: No double-precision Linux Godot editor found." >&2
    echo "  Run: systemctl --user start godot-build-linuxbsd  (in godot-images/)" >&2
    echo "  Or set GODOT_EDITOR=/path/to/godot.linuxbsd.editor.double.x86_64" >&2
    exit 1

# Download the Windows export template from the pinned godot-images release
# (GODOT_IMAGES_TAG) with curl.  Unpacks to tools/windows-template/.
fetch-windows-template:
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p tools/windows-template
    tag="${GODOT_IMAGES_TAG}"
    url="https://github.com/${GODOT_IMAGES_REPO}/releases/download/${tag}/windows-template-release.zip"
    echo "Fetching windows-template-release.zip from godot-images ${tag} ..."
    if ! curl -fL --retry 3 "$url" -o tools/windows-template/windows-template-release.zip; then
        echo "ERROR: could not download windows-template-release.zip from ${tag}." >&2
        echo "  Pick a release that has it (GODOT_IMAGES_TAG=...), or build it locally:" >&2
        echo "  cd ../godot-images && just fetch-llvm-mingw && just build-platform-target windows template_release" >&2
        exit 1
    fi
    cd tools/windows-template && unzip -o windows-template-release.zip
    echo "Windows template ready in tools/windows-template/"

# Resolve path to the Windows export template .exe (local tpz build or fetched).
_find-windows-template:
    #!/usr/bin/env bash
    set -euo pipefail
    # Local build from godot-images tpz/ takes priority
    local_tpz="${GODOT_IMAGES_DIR}/tpz"
    found=$(find "${local_tpz}" -name "godot.windows.template_release.double.x86_64*.exe" \
            -not -name "*.console.exe" 2>/dev/null | head -1)
    if [ -n "$found" ]; then echo "$found"; exit 0; fi
    # Fetched via just fetch-windows-template
    found=$(find tools/windows-template -name "godot.windows.template_release.double.x86_64*.exe" \
            -not -name "*.console.exe" 2>/dev/null | head -1)
    if [ -n "$found" ]; then echo "$found"; exit 0; fi
    echo "ERROR: Windows template not found. Run: just fetch-windows-template" >&2
    exit 1

# ── Game export ─────────────────────────────────────────────────────────

# Export Windows client and server builds using the Linux Godot editor.
export-windows:
    #!/usr/bin/env bash
    set -euo pipefail
    EDITOR=$(just _find-editor)
    TEMPLATE=$(just _find-windows-template)
    echo "Editor:   $EDITOR"
    echo "Template: $TEMPLATE"

    # Patch export_presets.cfg to use the resolved template path (in-place, restore after)
    cp export_presets.cfg export_presets.cfg.bak
    trap 'mv export_presets.cfg.bak export_presets.cfg' EXIT
    sed -i "s|custom_template/release=\".*\"|custom_template/release=\"$TEMPLATE\"|g" export_presets.cfg

    mkdir -p build/windows build/windows-server
    "$EDITOR" --headless --import . 2>/dev/null || true
    "$EDITOR" --headless --export-release "Windows Desktop" build/windows/loop-slice.exe
    "$EDITOR" --headless --export-release "Windows Dedicated Server" build/windows-server/loop-slice-server.exe
    echo "Exported Windows builds."

# ── MSIX packing ────────────────────────────────────────────────────────

# Pack and sign the client MSIX.
pack-msix-client version=MSIX_VERSION:
    #!/usr/bin/env bash
    set -euo pipefail
    pfx_args=""
    if [ -n "${PFX_PATH}" ]; then
        pfx_args="--pfx-path ${PFX_PATH} --pfx-password ${PFX_PASSWORD}"
    fi
    python3 packaging/msix/pack.py \
        --manifest packaging/msix/AppxManifest.xml \
        --assets   packaging/msix/assets \
        --bin-dir  build/windows \
        --version  "{{version}}" \
        --out-dir  dist \
        --name     v-sekai-loop-slice \
        --publisher "${MSIX_PUBLISHER}" \
        ${pfx_args}

# Pack and sign the server MSIX.
pack-msix-server version=MSIX_VERSION:
    #!/usr/bin/env bash
    set -euo pipefail
    pfx_args=""
    if [ -n "${PFX_PATH}" ]; then
        pfx_args="--pfx-path ${PFX_PATH} --pfx-password ${PFX_PASSWORD}"
    fi
    python3 packaging/msix-server/pack-server.py \
        --manifest packaging/msix-server/AppxManifest.xml \
        --assets   packaging/msix-server/assets \
        --bin-dir  build/windows-server \
        --version  "{{version}}" \
        --out-dir  dist \
        --name     v-sekai-loop-slice-server \
        --publisher "${MSIX_PUBLISHER}" \
        ${pfx_args}

# Pack both client and server MSIX packages.
pack-msix version=MSIX_VERSION:
    just pack-msix-client {{version}}
    just pack-msix-server {{version}}

# ── Full pipeline ────────────────────────────────────────────────────────

# Export game + pack + sign both MSIX packages.
build-msix version=MSIX_VERSION:
    just export-windows
    just pack-msix {{version}}
    @echo ""
    @echo "MSIX packages ready in dist/:"
    @ls dist/*.msix 2>/dev/null || true

# ── systemd service ──────────────────────────────────────────────────────

# Install the oneshot systemd user unit for hands-free MSIX builds.
# After install:
#   systemctl --user start  godot-loop-slice-msix
#   systemctl --user restart godot-loop-slice-msix   # re-run
#   journalctl --user -u godot-loop-slice-msix -f    # live logs
install-msix-service:
    #!/usr/bin/env bash
    set -euo pipefail
    UNIT_DIR="${HOME}/.config/systemd/user"
    mkdir -p "${UNIT_DIR}"
    sed "s|@WORKING_DIR@|${WORLD_PWD}|g" \
        "${WORLD_PWD}/quadlets/godot-loop-slice-msix.service" \
        > "${UNIT_DIR}/godot-loop-slice-msix.service"
    systemctl --user daemon-reload
    echo "Installed: ${UNIT_DIR}/godot-loop-slice-msix.service"
    echo ""
    echo "Start:   systemctl --user start godot-loop-slice-msix"
    echo "Re-run:  systemctl --user restart godot-loop-slice-msix"
    echo "Logs:    journalctl --user -u godot-loop-slice-msix -f"
