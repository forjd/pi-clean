#!/usr/bin/env bats

load './test_helper.bash'

setup() {
  setup_test_env
}

teardown() {
  teardown_test_env
}

@test "dry-run reports planned deletions and keeps files" {
  local agent_dir="$HOME_DIR/.pi/agent"
  local repo_one="$PROJECTS_ROOT/repo-one"
  local repo_two="$PROJECTS_ROOT/repo-two"
  local protected_dir="$repo_two/.agents/private-sessions"
  local shared_sessions="$repo_one/shared-sessions"

  mkdir -p "$agent_dir" "$repo_one/.pi" "$repo_two/.pi" "$protected_dir" "$shared_sessions" "$HOME_DIR/.agents/skills"

  cat > "$agent_dir/settings.json" <<EOF
{"packages":["npm:@foo/pi-tools@1.2.3","pi-skills",{"source":"git:github.com/user/repo"},{"source":"./local-ext"}]}
EOF
  cat > "$repo_one/.pi/settings.json" <<EOF
{"sessionDir":"../shared-sessions"}
EOF
  echo keep > "$HOME_DIR/.agents/skills/KEEP.txt"

  run "$SCRIPT" --dry-run --yes --scan-root "$PROJECTS_ROOT" --no-default-scan

  [ "$status" -eq 0 ]
  [[ "$output" == *"$agent_dir"* ]]
  [[ "$output" == *"$repo_one/.pi"* ]]
  [[ "$output" == *"$shared_sessions"* ]]
  [[ "$output" == *"uninstall global package: @foo/pi-tools"* ]]
  [[ "$output" == *"uninstall global package: pi-skills"* ]]
  [[ "$output" != *"github.com/user/repo"* ]]
  [[ "$output" != *"./local-ext"* ]]

  assert_exists "$agent_dir"
  assert_exists "$repo_one/.pi"
  assert_exists "$repo_two/.pi"
  assert_exists "$shared_sessions"
  assert_exists "$protected_dir"
  assert_exists "$HOME_DIR/.agents/skills/KEEP.txt"
}

@test "real cleanup removes pi paths and preserves .agents" {
  local agent_dir="$HOME_DIR/.pi/agent"
  local repo_one="$PROJECTS_ROOT/repo-one"
  local repo_two="$PROJECTS_ROOT/repo-two"
  local repo_three="$PROJECTS_ROOT/repo-three"
  local agent_sessions="$HOME_DIR/custom-agent-sessions"
  local repo_sessions="$repo_one/shared-sessions"
  local protected_dir="$repo_three/.agents/private-sessions"

  mkdir -p "$agent_dir" "$repo_one/.pi" "$repo_two/.pi" "$repo_three/.pi" \
           "$agent_sessions" "$repo_sessions" "$protected_dir" "$HOME_DIR/.agents/skills"

  cat > "$agent_dir/settings.json" <<EOF
{"sessionDir":"../../custom-agent-sessions"}
EOF
  cat > "$repo_one/.pi/settings.json" <<EOF
{"sessionDir":"../shared-sessions"}
EOF
  cat > "$repo_three/.pi/settings.json" <<EOF
{"sessionDir":"../.agents/private-sessions"}
EOF
  echo keep > "$HOME_DIR/.agents/skills/KEEP.txt"

  run "$SCRIPT" --yes --scan-root "$PROJECTS_ROOT" --no-default-scan

  [ "$status" -eq 0 ]
  [[ "$output" == *"Skipping .agents path: $protected_dir"* ]]

  assert_missing "$agent_dir"
  assert_missing "$repo_one/.pi"
  assert_missing "$repo_two/.pi"
  assert_missing "$repo_three/.pi"
  assert_missing "$agent_sessions"
  assert_missing "$repo_sessions"
  assert_exists "$protected_dir"
  assert_exists "$HOME_DIR/.agents/skills/KEEP.txt"
}

@test "--uninstall-cli dynamically finds package that provides pi executable" {
  local agent_dir="$HOME_DIR/.pi/agent"
  local fake_root="$TEST_ROOT/npm-global"
  local log_file="$TEST_ROOT/npm.log"

  mkdir -p "$agent_dir" "$fake_root"
  create_fake_package "$fake_root" "@mariozechner/pi-coding-agent" 1
  create_fake_npm "$BIN_DIR/npm" "$fake_root" "$log_file" "npm"

  run "$SCRIPT" --yes --uninstall-cli --no-default-scan

  [ "$status" -eq 0 ]
  [[ "$output" == *"uninstall global package: @mariozechner/pi-coding-agent"* ]]
  [[ "$output" == *"package providing 'pi' executable in npm global root"* ]]

  grep -F "npm uninstall -g @mariozechner/pi-coding-agent" "$log_file"
}

@test "configured npmCommand is used for package uninstalls" {
  local agent_dir="$HOME_DIR/.pi/agent"
  local fake_root="$TEST_ROOT/custom-npm-root"
  local log_file="$TEST_ROOT/custom-npm.log"
  local custom_npm="$TEST_ROOT/custom-npm"

  mkdir -p "$agent_dir" "$fake_root"
  create_fake_package "$fake_root" "pi-skills" 0
  create_fake_npm "$custom_npm" "$fake_root" "$log_file" "custom-npm"

  cat > "$agent_dir/settings.json" <<EOF
{"npmCommand":["$custom_npm"],"packages":["pi-skills"]}
EOF

  run "$SCRIPT" --yes --no-default-scan

  [ "$status" -eq 0 ]
  grep -F "custom-npm root -g" "$log_file"
  grep -F "custom-npm uninstall -g pi-skills" "$log_file"
}

@test "installer downloads script into local bin directory" {
  local fixture="$TEST_ROOT/fixture-pi-clean.sh"
  local install_dir="$HOME_DIR/.local/bin"
  local installed="$install_dir/pi-clean"

  cat > "$fixture" <<'EOF'
#!/usr/bin/env bash
printf 'fixture ok\n'
EOF
  chmod +x "$fixture"

  run env PI_CLEAN_INSTALL_SCRIPT_URL="file://$fixture" "$INSTALLER" --dir "$install_dir"

  [ "$status" -eq 0 ]
  [[ "$output" == *"Installed pi-clean to $installed"* ]]
  assert_exists "$installed"

  run "$installed"
  [ "$status" -eq 0 ]
  [ "$output" = "fixture ok" ]
}

@test "uninstaller removes installed command" {
  local uninstall_script="$REPO_ROOT/uninstall.sh"
  local install_dir="$HOME_DIR/.local/bin"
  local installed="$install_dir/pi-clean"

  mkdir -p "$install_dir"
  cat > "$installed" <<'EOF'
#!/usr/bin/env bash
printf 'installed\n'
EOF
  chmod +x "$installed"

  run "$uninstall_script" --dir "$install_dir"

  [ "$status" -eq 0 ]
  [[ "$output" == *"Removed $installed"* ]]
  assert_missing "$installed"
}
