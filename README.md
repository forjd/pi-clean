# pi-clean

A cautious cleanup script for removing pi data, project-local `.pi` directories, and pi-managed global npm packages.

> [!WARNING]
> This tool deletes files and uninstalls packages. Always run `--dry-run` first and review the plan before running it for real.

## What it does

`pi-clean.sh` can:

- remove the active pi agent directory
  - `PI_CODING_AGENT_DIR` if set
  - otherwise `~/.pi/agent`
- remove project-local `.pi` directories
- remove custom `sessionDir` paths referenced by pi settings
- uninstall global npm packages referenced by pi global settings
- optionally uninstall the package that currently provides the `pi` executable

## Safety model

The script is designed to remove **pi-managed data** without wandering into unrelated files.

It intentionally:

- does **not** touch `~/.agents`
- skips any path inside `.agents`
- does **not** delete arbitrary local package source repos referenced from pi settings
- skips git and URL package sources for npm uninstall discovery
- prints a full plan before making changes

## What it does not remove

By design, this script does **not** delete:

- `~/.agents`
- arbitrary local directories referenced as pi package sources
- arbitrary git clones outside pi-managed directories
- shell config entries like API keys in `~/.zshrc` or `~/.bashrc`

If you exported provider API keys in shell startup files, remove those manually.

## Requirements

- Bash
- Python 3
- Optional, for uninstalling global packages:
  - `npm`, `pnpm`, or `yarn`

The script is tested against macOS' default Bash 3.2 and modern Linux Bash.

## Usage

```bash
./pi-clean.sh --dry-run
./pi-clean.sh --yes
./pi-clean.sh --yes --uninstall-cli
```

### Options

```text
--uninstall-cli      Also uninstall any global package that provides the 'pi' executable
--scan-root DIR      Also scan DIR for project-local .pi directories (repeatable)
--no-default-scan    Do not automatically scan ~/Projects
--agent-dir DIR      Override the pi agent dir to clean
--dry-run            Show what would be removed, then exit
--yes                Do not prompt for confirmation
--verbose            Show extra details
-h, --help           Show help
```

## Recommended workflow

### 1. Preview everything

```bash
./pi-clean.sh --dry-run
```

### 2. Clean pi data and packages discovered from pi settings

```bash
./pi-clean.sh --yes
```

### 3. Also remove the `pi` CLI package

```bash
./pi-clean.sh --yes --uninstall-cli
```

## Examples

### Scan extra roots

```bash
./pi-clean.sh --dry-run --scan-root ~/work --scan-root ~/src
```

### Clean a custom agent dir

```bash
./pi-clean.sh --yes --agent-dir ~/custom/pi-agent
```

### Use only explicit scan roots

```bash
./pi-clean.sh --dry-run --no-default-scan --scan-root ~/code
```

## How global package discovery works

### Packages from pi settings

The script reads the active pi global settings file and extracts npm package names from the `packages` array.

It will consider entries like:

- `npm:@scope/pkg@1.2.3` → `@scope/pkg`
- `plain-package-name` → `plain-package-name`

It skips entries that are clearly not global npm packages, such as:

- `git:...`
- `https://...`
- `ssh://...`
- local paths like `./something` or `/abs/path`

### CLI package detection

With `--uninstall-cli`, the script scans global package roots and looks for a package whose `package.json` exposes a `bin.pi` entry.

That avoids hardcoding a single package name.

## Conventional commits

This repo enforces Conventional Commits in pull requests:

- commit messages are linted with `commitlint`
- pull request titles must also be semantic

Examples:

- `feat: add npmCommand-aware uninstall detection`
- `fix: preserve .agents paths during cleanup`
- `docs: clarify what local package sources are skipped`
- `chore: update CI workflow`

If you use squash merges, make sure the PR title is also a valid conventional commit, since that title often becomes the final commit message on `main`.

## Releases

This repo uses Release Please.

On pushes to `main`, Release Please will:

- inspect conventional commits
- open or update a release PR
- generate changelog entries
- create a GitHub release after the release PR is merged

In practice:

- `feat:` usually triggers a minor release
- `fix:` usually triggers a patch release
- `feat!:` or a `BREAKING CHANGE:` footer triggers a major release

## Development

### Lint

```bash
make lint
```

### Test

```bash
make test
```

### Full local check

```bash
make check
```

## CI

GitHub Actions runs:

- `bash -n`
- `shellcheck`
- integration tests with Bats
- conventional commit checks for pull requests
- Release Please on `main`

on both:

- Ubuntu
- macOS

## License

MIT
