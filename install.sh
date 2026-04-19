#!/usr/bin/env bash
set -eo pipefail

REPO="${PI_CLEAN_INSTALL_REPO:-forjd/pi-clean}"
RAW_BASE_URL="${PI_CLEAN_RAW_BASE_URL:-https://raw.githubusercontent.com}"
API_BASE_URL="${PI_CLEAN_API_BASE_URL:-https://api.github.com/repos}"
INSTALL_DIR="${INSTALL_DIR:-$HOME/.local/bin}"
BIN_NAME="${BIN_NAME:-pi-clean}"
PINNED_REF="${PI_CLEAN_INSTALL_REF:-}"
DIRECT_SCRIPT_URL="${PI_CLEAN_INSTALL_SCRIPT_URL:-}"
USE_MAIN=0
QUIET=0

info() {
  if (( QUIET == 0 )); then
    printf '[info] %s\n' "$*"
  fi
}

warn() {
  printf '[warn] %s\n' "$*" >&2
}

fail() {
  printf '[error] %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<EOF
Usage: install.sh [options]

Installs pi-clean into a local bin directory.

Options:
  --dir DIR           Install directory (default: ~/.local/bin)
  --bin-name NAME     Installed command name (default: pi-clean)
  --version REF       Install a specific git ref or tag (for example: v1.0.0)
  --main              Install from the main branch instead of the latest release
  --repo OWNER/REPO   Install from a different GitHub repo
  --quiet             Reduce installer output
  -h, --help          Show this help

Environment overrides:
  INSTALL_DIR
  BIN_NAME
  PI_CLEAN_INSTALL_REPO
  PI_CLEAN_INSTALL_REF
  PI_CLEAN_INSTALL_SCRIPT_URL
  PI_CLEAN_RAW_BASE_URL
  PI_CLEAN_API_BASE_URL

Examples:
  curl -fsSL https://raw.githubusercontent.com/forjd/pi-clean/main/install.sh | bash
  wget -qO- https://raw.githubusercontent.com/forjd/pi-clean/main/install.sh | bash
  curl -fsSL https://raw.githubusercontent.com/forjd/pi-clean/main/install.sh | bash -s -- --main
  curl -fsSL https://raw.githubusercontent.com/forjd/pi-clean/main/install.sh | bash -s -- --version v1.0.0
EOF
}

have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

need_cmd() {
  have_cmd "$1" || fail "Missing required command: $1"
}

fetch_text() {
  local url="$1"
  if have_cmd curl; then
    curl -fsSL "$url"
    return
  fi
  if have_cmd wget; then
    wget -qO- "$url"
    return
  fi
  fail "Need curl or wget"
}

fetch_file() {
  local url="$1"
  local output="$2"
  if have_cmd curl; then
    curl -fsSL "$url" -o "$output"
    return
  fi
  if have_cmd wget; then
    wget -qO "$output" "$url"
    return
  fi
  fail "Need curl or wget"
}

resolve_latest_release_ref() {
  local api_url="$API_BASE_URL/$REPO/releases/latest"
  local json
  json="$(fetch_text "$api_url" 2>/dev/null || true)"

  if [[ -z "$json" ]]; then
    return 1
  fi

  python3 - <<'PY' "$json"
import json, sys
try:
    payload = json.loads(sys.argv[1])
except Exception:
    sys.exit(1)
value = payload.get('tag_name')
if isinstance(value, str) and value.strip():
    print(value.strip())
    sys.exit(0)
sys.exit(1)
PY
}

install_file() {
  local source="$1"
  local destination="$2"

  if have_cmd install; then
    install -m 0755 "$source" "$destination"
  else
    cp "$source" "$destination"
    chmod 0755 "$destination"
  fi
}

print_path_hint() {
  if [[ ":$PATH:" == *":$INSTALL_DIR:"* ]]; then
    return 0
  fi

  cat <<EOF

Add $INSTALL_DIR to your PATH if needed:
  export PATH="$INSTALL_DIR:\$PATH"
EOF
}

parse_args() {
  local arg
  while (($# > 0)); do
    arg="$1"
    case "$arg" in
      --dir)
        shift
        (($# > 0)) || fail "--dir requires a value"
        INSTALL_DIR="$1"
        ;;
      --bin-name)
        shift
        (($# > 0)) || fail "--bin-name requires a value"
        BIN_NAME="$1"
        ;;
      --version)
        shift
        (($# > 0)) || fail "--version requires a value"
        PINNED_REF="$1"
        ;;
      --main)
        USE_MAIN=1
        ;;
      --repo)
        shift
        (($# > 0)) || fail "--repo requires a value"
        REPO="$1"
        ;;
      --quiet)
        QUIET=1
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        fail "Unknown option: $arg"
        ;;
    esac
    shift
  done
}

main() {
  local ref=""
  local script_url=""
  local temp_file=""
  local destination=""

  need_cmd python3
  parse_args "$@"

  if [[ -n "$DIRECT_SCRIPT_URL" ]]; then
    script_url="$DIRECT_SCRIPT_URL"
  else
    if [[ -n "$PINNED_REF" ]]; then
      ref="$PINNED_REF"
      info "Installing pi-clean from ref: $ref"
    elif (( USE_MAIN )); then
      ref="main"
      info "Installing pi-clean from main"
    else
      ref="$(resolve_latest_release_ref || true)"
      if [[ -n "$ref" ]]; then
        info "Installing pi-clean from latest release: $ref"
      else
        ref="main"
        warn "Could not resolve latest release, falling back to main"
      fi
    fi

    script_url="$RAW_BASE_URL/$REPO/$ref/pi-clean.sh"
  fi

  temp_file="$(mktemp "${TMPDIR:-/tmp}/pi-clean-install.XXXXXX")"
  fetch_file "$script_url" "$temp_file"
  chmod 0755 "$temp_file"

  mkdir -p "$INSTALL_DIR"
  destination="$INSTALL_DIR/$BIN_NAME"
  install_file "$temp_file" "$destination"
  rm -f "$temp_file"

  info "Installed $BIN_NAME to $destination"
  print_path_hint

  cat <<EOF

Next step:
  $BIN_NAME --dry-run
EOF
}

main "$@"
