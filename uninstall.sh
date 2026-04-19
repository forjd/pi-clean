#!/usr/bin/env bash
set -eo pipefail

INSTALL_DIR="${INSTALL_DIR:-$HOME/.local/bin}"
BIN_NAME="${BIN_NAME:-pi-clean}"
PRUNE_DIR=0
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
Usage: uninstall.sh [options]

Uninstalls the locally installed pi-clean command.

Options:
  --dir DIR           Install directory to remove from (default: ~/.local/bin)
  --bin-name NAME     Installed command name to remove (default: pi-clean)
  --prune-dir         Remove the install directory if it becomes empty
  --quiet             Reduce output
  -h, --help          Show this help

Environment overrides:
  INSTALL_DIR
  BIN_NAME

Examples:
  curl -fsSL https://raw.githubusercontent.com/forjd/pi-clean/main/uninstall.sh | bash
  wget -qO- https://raw.githubusercontent.com/forjd/pi-clean/main/uninstall.sh | bash
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
      --prune-dir)
        PRUNE_DIR=1
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
  local target=""

  parse_args "$@"

  mkdir -p "$INSTALL_DIR"
  target="$INSTALL_DIR/$BIN_NAME"

  if [[ -e "$target" || -L "$target" ]]; then
    rm -f "$target"
    info "Removed $target"
  else
    warn "Nothing to remove at $target"
  fi

  if (( PRUNE_DIR )); then
    rmdir "$INSTALL_DIR" 2>/dev/null || true
  fi
}

main "$@"
