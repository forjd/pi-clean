#!/usr/bin/env bash
set -eo pipefail

APP_NAME="pi-clean"

YES=0
DRY_RUN=0
VERBOSE=0
UNINSTALL_CLI=0
USE_DEFAULT_SCAN=1
AGENT_DIR_OVERRIDE=""
SCAN_ROOTS=()
DELETE_PATHS=()
DELETE_REASONS=()
UNINSTALL_PACKAGES=()
UNINSTALL_REASONS=()
NPM_COMMAND=()

action_echo() {
  printf '%s\n' "$*"
}

info() {
  printf '[info] %s\n' "$*"
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
Usage: $APP_NAME [options]

Removes pi data and project-local .pi directories.
Does NOT touch ~/.agents.

Default behavior:
  - cleans the active pi agent dir (PI_CODING_AGENT_DIR or ~/.pi/agent)
  - removes project-local .pi directories under ~/Projects
  - removes custom sessionDir locations referenced by pi settings
  - uninstalls globally installed npm packages referenced by pi global settings
  - keeps the pi CLI unless --uninstall-cli is passed

Options:
  --uninstall-cli      Also uninstall any global package that provides the 'pi' executable
  --scan-root DIR      Also scan DIR for project-local .pi directories (repeatable)
  --no-default-scan    Do not automatically scan ~/Projects
  --agent-dir DIR      Override the pi agent dir to clean
  --dry-run            Show what would be removed, then exit
  --yes                Do not prompt for confirmation
  --verbose            Show extra details
  -h, --help           Show this help

Examples:
  $APP_NAME --dry-run
  $APP_NAME --yes --uninstall-cli
  $APP_NAME --scan-root ~/work --scan-root ~/src
EOF
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"
}

path_exists() {
  [[ -e "$1" || -L "$1" ]]
}

abs_path() {
  python3 - "$1" <<'PY'
import os, sys
print(os.path.abspath(os.path.expanduser(sys.argv[1])))
PY
}

resolve_relative_path() {
  python3 - "$1" "$2" <<'PY'
import os, sys
base = os.path.abspath(os.path.expanduser(sys.argv[1]))
value = os.path.expanduser(sys.argv[2])
if os.path.isabs(value):
    print(os.path.abspath(value))
else:
    print(os.path.abspath(os.path.join(base, value)))
PY
}

extract_session_dir() {
  python3 - "$1" <<'PY'
import json, sys
path = sys.argv[1]
try:
    with open(path, 'r', encoding='utf-8') as f:
        data = json.load(f)
    value = data.get('sessionDir')
    if isinstance(value, str) and value.strip():
        print(value)
except Exception:
    pass
PY
}

extract_npm_command() {
  python3 - "$1" <<'PY'
import json, sys
path = sys.argv[1]
try:
    with open(path, 'r', encoding='utf-8') as f:
        data = json.load(f)
    value = data.get('npmCommand')
    if isinstance(value, list) and all(isinstance(x, str) and x.strip() for x in value):
        for item in value:
            print(item)
except Exception:
    pass
PY
}

extract_npm_packages() {
  python3 - "$1" <<'PY'
import json, sys

path = sys.argv[1]

def source_from_entry(entry):
    if isinstance(entry, str):
        return entry.strip()
    if isinstance(entry, dict):
        source = entry.get('source')
        if isinstance(source, str):
            return source.strip()
    return ''

def npm_name_from_source(source):
    if not source:
        return None
    lower = source.lower()
    if lower.startswith(('git:', 'http://', 'https://', 'ssh://', 'git://')):
        return None
    if source.startswith(('/', './', '../', '~')):
        return None

    spec = source[4:].strip() if source.startswith('npm:') else source.strip()
    if not spec:
        return None

    if spec.startswith('@'):
        tail = spec[1:]
        if '@' in tail:
            return spec.rsplit('@', 1)[0]
        return spec

    return spec.split('@', 1)[0]

try:
    with open(path, 'r', encoding='utf-8') as f:
        data = json.load(f)
except Exception:
    sys.exit(0)

packages = data.get('packages')
if not isinstance(packages, list):
    sys.exit(0)

seen = set()
for entry in packages:
    source = source_from_entry(entry)
    name = npm_name_from_source(source)
    if name and name not in seen:
        seen.add(name)
        print(name)
PY
}

extract_cli_packages_from_node_root() {
  python3 - "$1" <<'PY'
import json, os, sys

root = os.path.abspath(os.path.expanduser(sys.argv[1]))
seen = set()

if not os.path.isdir(root):
    sys.exit(0)

def package_dirs(node_root):
    try:
        entries = sorted(os.listdir(node_root))
    except Exception:
        return
    for entry in entries:
        if entry.startswith('.'):
            continue
        path = os.path.join(node_root, entry)
        if entry.startswith('@') and os.path.isdir(path):
            try:
                scoped = sorted(os.listdir(path))
            except Exception:
                continue
            for sub in scoped:
                subpath = os.path.join(path, sub)
                if os.path.isfile(os.path.join(subpath, 'package.json')):
                    yield subpath
            continue
        if os.path.isfile(os.path.join(path, 'package.json')):
            yield path

for pkg_dir in package_dirs(root):
    pkg_json = os.path.join(pkg_dir, 'package.json')
    try:
        with open(pkg_json, 'r', encoding='utf-8') as f:
            data = json.load(f)
    except Exception:
        continue

    name = data.get('name')
    if not isinstance(name, str) or not name.strip():
        continue

    bin_value = data.get('bin')
    provides_pi = False
    if isinstance(bin_value, dict):
        provides_pi = 'pi' in bin_value
    elif isinstance(bin_value, str):
        package_basename = name.split('/')[-1]
        provides_pi = package_basename == 'pi'

    if provides_pi and name not in seen:
        seen.add(name)
        print(name)
PY
}

find_delete_index() {
  local target="$1"
  local i
  for ((i = 0; i < ${#DELETE_PATHS[@]}; i++)); do
    if [[ "${DELETE_PATHS[$i]}" == "$target" ]]; then
      printf '%s\n' "$i"
      return 0
    fi
  done
  printf '%s\n' "-1"
}

reason_for_path() {
  local path="$1"
  local idx
  idx="$(find_delete_index "$path")"
  if [[ "$idx" == "-1" ]]; then
    printf '%s\n' ""
  else
    printf '%s\n' "${DELETE_REASONS[$idx]}"
  fi
}

find_uninstall_index() {
  local target="$1"
  local i
  for ((i = 0; i < ${#UNINSTALL_PACKAGES[@]}; i++)); do
    if [[ "${UNINSTALL_PACKAGES[$i]}" == "$target" ]]; then
      printf '%s\n' "$i"
      return 0
    fi
  done
  printf '%s\n' "-1"
}

add_uninstall_package() {
  local package_name="$1"
  local reason="$2"
  local idx

  [[ -n "${package_name// }" ]] || return 0

  idx="$(find_uninstall_index "$package_name")"
  if [[ "$idx" == "-1" ]]; then
    UNINSTALL_PACKAGES+=("$package_name")
    UNINSTALL_REASONS+=("$reason")
  else
    case ";${UNINSTALL_REASONS[$idx]};" in
      *";$reason;"*) ;;
      *) UNINSTALL_REASONS[idx]="${UNINSTALL_REASONS[idx]}; $reason" ;;
    esac
  fi
}

add_delete_path() {
  local raw_path="$1"
  local reason="$2"
  local path idx

  [[ -n "${raw_path// }" ]] || return 0
  path="$(abs_path "$raw_path")"

  if ! path_exists "$path"; then
    if (( VERBOSE )); then
      info "Skipping missing path: $path"
    fi
    return 0
  fi

  case "$path" in
    /|"$HOME")
      warn "Refusing to delete unsafe path: $path ($reason)"
      return 0
      ;;
    "$HOME/.agents"|"$HOME/.agents/"*)
      warn "Skipping protected path: $path"
      return 0
      ;;
  esac

  if [[ "$path" == */.agents || "$path" == */.agents/* ]]; then
    warn "Skipping .agents path: $path"
    return 0
  fi

  idx="$(find_delete_index "$path")"
  if [[ "$idx" == "-1" ]]; then
    DELETE_PATHS+=("$path")
    DELETE_REASONS+=("$reason")
  else
    case ";${DELETE_REASONS[$idx]};" in
      *";$reason;"*) ;;
      *) DELETE_REASONS[idx]="${DELETE_REASONS[idx]}; $reason" ;;
    esac
  fi
}

scan_project_pi_dirs() {
  local root="$1"
  local settings session_dir resolved dir

  if [[ ! -d "$root" ]]; then
    if (( VERBOSE )); then
      info "Scan root does not exist: $root"
    fi
    return 0
  fi

  if (( VERBOSE )); then
    info "Scanning for project .pi dirs under: $root"
  fi

  while IFS= read -r dir; do
    [[ -n "$dir" ]] || continue
    add_delete_path "$dir" "project-local .pi directory"

    settings="$dir/settings.json"
    if [[ -f "$settings" ]]; then
      while IFS= read -r session_dir; do
        [[ -n "$session_dir" ]] || continue
        resolved="$(resolve_relative_path "$dir" "$session_dir")"
        add_delete_path "$resolved" "custom sessionDir from $settings"
      done < <(extract_session_dir "$settings")
    fi
  done < <(
    find "$root" \
      \( -type d \( -name .git -o -name node_modules -o -name dist -o -name build -o -name .next -o -name .cache \) -prune \) -o \
      \( -type d -name .pi -print \) 2>/dev/null
  )
}

load_npm_command_from_settings() {
  local settings="$1"
  local item

  NPM_COMMAND=()
  [[ -f "$settings" ]] || return 0

  while IFS= read -r item; do
    [[ -n "$item" ]] || continue
    NPM_COMMAND+=("$item")
  done < <(extract_npm_command "$settings")
}

collect_global_packages_from_settings() {
  local settings="$1"
  local package_name

  [[ -f "$settings" ]] || return 0

  while IFS= read -r package_name; do
    [[ -n "$package_name" ]] || continue
    add_uninstall_package "$package_name" "global npm package from $settings"
  done < <(extract_npm_packages "$settings")
}

collect_cli_packages_from_node_root() {
  local root="$1"
  local label="$2"
  local package_name

  [[ -n "$root" ]] || return 0

  while IFS= read -r package_name; do
    [[ -n "$package_name" ]] || continue
    add_uninstall_package "$package_name" "package providing 'pi' executable in $label"
  done < <(extract_cli_packages_from_node_root "$root")
}

collect_cli_packages() {
  local root=""
  local yarn_dir=""

  if ((${#NPM_COMMAND[@]} > 0)); then
    root="$("${NPM_COMMAND[@]}" root -g 2>/dev/null || true)"
    collect_cli_packages_from_node_root "$root" "configured npmCommand root"
  fi

  if command -v npm >/dev/null 2>&1; then
    root="$(npm root -g 2>/dev/null || true)"
    collect_cli_packages_from_node_root "$root" "npm global root"
  fi

  if command -v pnpm >/dev/null 2>&1; then
    root="$(pnpm root -g 2>/dev/null || true)"
    collect_cli_packages_from_node_root "$root" "pnpm global root"
  fi

  if command -v yarn >/dev/null 2>&1; then
    yarn_dir="$(yarn global dir 2>/dev/null || true)"
    if [[ -n "$yarn_dir" ]]; then
      collect_cli_packages_from_node_root "$yarn_dir/node_modules" "yarn global dir"
    fi
  fi
}

sorted_unique_delete_paths() {
  printf '%s\n' "${DELETE_PATHS[@]}" | \
    awk 'NF && !seen[$0]++ { printf "%d\t%s\n", length($0), $0 }' | \
    sort -n -k1,1 -k2,2 | \
    cut -f2-
}

filter_nested_paths() {
  local filtered_paths=()
  local filtered_reasons=()
  local path keep skip reason

  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    skip=0
    for keep in "${filtered_paths[@]}"; do
      if [[ "$path" == "$keep" || "$path" == "$keep/"* ]]; then
        skip=1
        break
      fi
    done

    if (( skip == 0 )); then
      reason="$(reason_for_path "$path")"
      filtered_paths+=("$path")
      filtered_reasons+=("$reason")
    fi
  done < <(sorted_unique_delete_paths)

  DELETE_PATHS=("${filtered_paths[@]}")
  DELETE_REASONS=("${filtered_reasons[@]}")
}

print_plan() {
  local i

  printf '\nPlanned cleanup:\n'
  if ((${#DELETE_PATHS[@]} > 0)); then
    for ((i = 0; i < ${#DELETE_PATHS[@]}; i++)); do
      printf '  - %s\n' "${DELETE_PATHS[$i]}"
      printf '      %s\n' "${DELETE_REASONS[$i]}"
    done
  else
    printf '  - no pi paths found to delete\n'
  fi

  if ((${#UNINSTALL_PACKAGES[@]} > 0)); then
    for ((i = 0; i < ${#UNINSTALL_PACKAGES[@]}; i++)); do
      printf '  - uninstall global package: %s\n' "${UNINSTALL_PACKAGES[$i]}"
      printf '      %s\n' "${UNINSTALL_REASONS[$i]}"
    done
  fi

  printf '\n'
}

confirm() {
  local reply
  if (( YES )); then
    return 0
  fi

  printf 'Type yes to continue: '
  read -r reply
  [[ "$reply" == "yes" ]]
}

remove_path() {
  local path="$1"
  if (( DRY_RUN )); then
    action_echo "[dry-run] rm -rf -- $path"
  else
    rm -rf -- "$path"
    info "Removed: $path"
  fi
}

prune_empty_default_pi_root() {
  local default_root="$HOME/.pi"
  if [[ -d "$default_root" ]]; then
    if (( DRY_RUN )); then
      action_echo "[dry-run] rmdir $default_root (if empty)"
    else
      rmdir "$default_root" 2>/dev/null || true
    fi
  fi
}

run_or_dry() {
  if (( DRY_RUN )); then
    action_echo "[dry-run] $*"
    return 0
  fi
  "$@"
}

try_uninstall_with_npm_like() {
  local package_name="$1"
  local label="$2"
  shift 2

  local root=""
  [[ $# -gt 0 ]] || return 1

  root="$("$@" root -g 2>/dev/null || true)"
  if [[ -n "$root" ]] && path_exists "$root/$package_name"; then
    info "Uninstalling $package_name via $label"
    run_or_dry "$@" uninstall -g "$package_name" || warn "$label uninstall failed for $package_name"
    return 0
  fi

  return 1
}

try_uninstall_with_yarn() {
  local package_name="$1"
  local yarn_dir=""

  command -v yarn >/dev/null 2>&1 || return 1

  yarn_dir="$(yarn global dir 2>/dev/null || true)"
  if [[ -n "$yarn_dir" ]] && path_exists "$yarn_dir/node_modules/$package_name"; then
    info "Uninstalling $package_name via yarn"
    run_or_dry yarn global remove "$package_name" || warn "yarn global remove failed for $package_name"
    return 0
  fi

  return 1
}

uninstall_discovered_packages() {
  local package_name=""
  local i

  for ((i = 0; i < ${#UNINSTALL_PACKAGES[@]}; i++)); do
    package_name="${UNINSTALL_PACKAGES[$i]}"

    if ((${#NPM_COMMAND[@]} > 0)) && try_uninstall_with_npm_like "$package_name" "configured npmCommand" "${NPM_COMMAND[@]}"; then
      continue
    fi

    if command -v npm >/dev/null 2>&1 && try_uninstall_with_npm_like "$package_name" "npm" npm; then
      continue
    fi

    if command -v pnpm >/dev/null 2>&1 && try_uninstall_with_npm_like "$package_name" "pnpm" pnpm; then
      continue
    fi

    if try_uninstall_with_yarn "$package_name"; then
      continue
    fi

    warn "Could not detect a global install of $package_name."
    warn "It may already be gone, installed another way, or only referenced as a local/git package source."
  done
}

parse_args() {
  local arg
  while (($# > 0)); do
    arg="$1"
    case "$arg" in
      --uninstall-cli)
        UNINSTALL_CLI=1
        ;;
      --scan-root)
        shift
        (($# > 0)) || fail "--scan-root requires a directory"
        SCAN_ROOTS+=("$(abs_path "$1")")
        ;;
      --no-default-scan)
        USE_DEFAULT_SCAN=0
        ;;
      --agent-dir)
        shift
        (($# > 0)) || fail "--agent-dir requires a directory"
        AGENT_DIR_OVERRIDE="$1"
        ;;
      --dry-run)
        DRY_RUN=1
        ;;
      --yes)
        YES=1
        ;;
      --verbose)
        VERBOSE=1
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
  local agent_dir=""
  local settings=""
  local session_dir=""
  local resolved=""
  local root=""
  local i

  need_cmd python3
  parse_args "$@"

  if [[ -n "$AGENT_DIR_OVERRIDE" ]]; then
    agent_dir="$(abs_path "$AGENT_DIR_OVERRIDE")"
  elif [[ -n "${PI_CODING_AGENT_DIR:-}" ]]; then
    agent_dir="$(abs_path "$PI_CODING_AGENT_DIR")"
  else
    agent_dir="$HOME/.pi/agent"
  fi

  add_delete_path "$agent_dir" "pi agent dir"

  settings="$agent_dir/settings.json"
  load_npm_command_from_settings "$settings"
  collect_global_packages_from_settings "$settings"

  if (( UNINSTALL_CLI )); then
    collect_cli_packages
  fi

  if [[ -f "$settings" ]]; then
    while IFS= read -r session_dir; do
      [[ -n "$session_dir" ]] || continue
      resolved="$(resolve_relative_path "$agent_dir" "$session_dir")"
      add_delete_path "$resolved" "custom sessionDir from $settings"
    done < <(extract_session_dir "$settings")
  fi

  if (( USE_DEFAULT_SCAN )); then
    SCAN_ROOTS+=("$HOME/Projects")
  fi

  for ((i = 0; i < ${#SCAN_ROOTS[@]}; i++)); do
    root="${SCAN_ROOTS[$i]}"
    scan_project_pi_dirs "$root"
  done

  filter_nested_paths
  print_plan

  if ((${#DELETE_PATHS[@]} == 0)) && ((${#UNINSTALL_PACKAGES[@]} == 0)); then
    info "Nothing to do."
    exit 0
  fi

  if (( DRY_RUN )); then
    info "Dry run only. No changes were made."
    exit 0
  fi

  confirm || fail "Aborted."

  for ((i = 0; i < ${#DELETE_PATHS[@]}; i++)); do
    remove_path "${DELETE_PATHS[$i]}"
  done

  prune_empty_default_pi_root

  if ((${#UNINSTALL_PACKAGES[@]} > 0)); then
    uninstall_discovered_packages
  fi

  info "Done. ~/.agents was not touched."
}

main "$@"
