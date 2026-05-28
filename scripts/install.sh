#!/usr/bin/env bash
set -euo pipefail

OWNER="martinffx"
REPO="opencode"
BINARY_NAME="opencode"

get_os() {
  case "$(uname -s)" in
    Linux*)     echo "linux" ;;
    Darwin*)    echo "darwin" ;;
    CYGWIN*|MINGW*|MSYS*) echo "windows" ;;
    *)          echo "unknown" ;;
  esac
}

get_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo "x64" ;;
    arm64|aarch64) echo "arm64" ;;
    *)            echo "unknown" ;;
  esac
}

check_avx2() {
  if [ "$(get_os)" = "linux" ]; then
    if grep -q avx2 /proc/cpuinfo 2>/dev/null; then
      echo "true"
    else
      echo "false"
    fi
  elif [ "$(get_os)" = "darwin" ]; then
    if sysctl -a 2>/dev/null | grep -q AVX2; then
      echo "true"
    else
      echo "false"
    fi
  else
    echo "true"
  fi
}

OS=$(get_os)
ARCH=$(get_arch)

if [ "$OS" = "unknown" ]; then
  echo "Unsupported OS: $(uname -s)"
  exit 1
fi

if [ "$ARCH" = "unknown" ]; then
  echo "Unsupported architecture: $(uname -m)"
  exit 1
fi

if [ "$OS" = "windows" ]; then
  echo "Windows is not supported by this installer. Please download the binary manually from:"
  echo "https://github.com/${OWNER}/${REPO}/releases/latest"
  exit 1
fi

AVX2=$(check_avx2)

LATEST_TAG=$(curl -fsSL "https://api.github.com/repos/${OWNER}/${REPO}/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')

if [ -z "$LATEST_TAG" ]; then
  echo "Failed to fetch latest release tag"
  exit 1
fi

VERSION=${LATEST_TAG#v}

ASSET_BASE="${BINARY_NAME}-${OS}-${ARCH}"
if [ "$AVX2" = "false" ]; then
  ASSET_BASE="${ASSET_BASE}-baseline"
fi

if [ "$OS" = "linux" ]; then
  ASSET="${ASSET_BASE}.tar.gz"
else
  ASSET="${ASSET_BASE}.zip"
fi

DOWNLOAD_URL="https://github.com/${OWNER}/${REPO}/releases/download/${LATEST_TAG}/${ASSET}"

echo "Installing opencode fork ${LATEST_TAG} for ${OS}-${ARCH}..."

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

echo "Downloading ${ASSET}..."
curl -fsSL "$DOWNLOAD_URL" -o "${TMP_DIR}/${ASSET}"

if [ "$OS" = "linux" ]; then
  tar -xzf "${TMP_DIR}/${ASSET}" -C "$TMP_DIR"
else
  unzip -q "${TMP_DIR}/${ASSET}" -d "$TMP_DIR"
fi

INSTALL_DIR="/usr/local/bin"
if [ ! -w "$INSTALL_DIR" ]; then
  INSTALL_DIR="${HOME}/.local/bin"
  mkdir -p "$INSTALL_DIR"
fi

cp "${TMP_DIR}/${BINARY_NAME}" "${INSTALL_DIR}/${BINARY_NAME}"
chmod +x "${INSTALL_DIR}/${BINARY_NAME}"

echo "Installed ${BINARY_NAME} to ${INSTALL_DIR}/${BINARY_NAME}"

if ! command -v opencode &> /dev/null; then
  echo ""
  echo "WARNING: ${INSTALL_DIR} is not in your PATH."
  echo "Add the following to your shell profile:"
  echo "  export PATH=\"${INSTALL_DIR}:\$PATH\""
fi

echo ""
echo "Run 'opencode --version' to verify the installation."
