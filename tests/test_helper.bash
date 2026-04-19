TEST_ORIGINAL_PATH="$PATH"

setup_test_env() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  SCRIPT="$REPO_ROOT/pi-clean.sh"
  TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/pi-clean-test.XXXXXX")"
  HOME_DIR="$TEST_ROOT/home"
  PROJECTS_ROOT="$HOME_DIR/Projects"
  BIN_DIR="$TEST_ROOT/bin"

  mkdir -p "$HOME_DIR" "$PROJECTS_ROOT" "$BIN_DIR"

  export REPO_ROOT SCRIPT TEST_ROOT HOME_DIR PROJECTS_ROOT BIN_DIR
  export HOME="$HOME_DIR"
  export PATH="$BIN_DIR:$TEST_ORIGINAL_PATH"
}

teardown_test_env() {
  rm -rf "$TEST_ROOT"
}

package_dir_for() {
  local root="$1"
  local package_name="$2"

  if [[ "$package_name" == @*/* ]]; then
    printf '%s/%s/%s\n' "$root" "${package_name%%/*}" "${package_name#*/}"
  else
    printf '%s/%s\n' "$root" "$package_name"
  fi
}

create_fake_package() {
  local root="$1"
  local package_name="$2"
  local provides_pi="${3:-0}"
  local package_dir

  package_dir="$(package_dir_for "$root" "$package_name")"
  mkdir -p "$package_dir"

  if [[ "$provides_pi" == "1" ]]; then
    cat > "$package_dir/package.json" <<EOF
{"name":"$package_name","bin":{"pi":"bin/pi.js"}}
EOF
  else
    cat > "$package_dir/package.json" <<EOF
{"name":"$package_name"}
EOF
  fi
}

create_fake_npm() {
  local command_path="$1"
  local package_root="$2"
  local log_file="$3"
  local label="$4"

  cat > "$command_path" <<EOF
#!/usr/bin/env bash
set -e
printf '%s %s\\n' '$label' "\$*" >> "$log_file"
if [[ "\$1" == "root" && "\$2" == "-g" ]]; then
  printf '%s\\n' "$package_root"
  exit 0
fi
if [[ "\$1" == "uninstall" && "\$2" == "-g" ]]; then
  exit 0
fi
exit 0
EOF
  chmod +x "$command_path"
}

assert_exists() {
  local path="$1"
  [[ -e "$path" || -L "$path" ]]
}

assert_missing() {
  local path="$1"
  [[ ! -e "$path" && ! -L "$path" ]]
}
