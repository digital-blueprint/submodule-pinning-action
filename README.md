# Submodule Pinning Check

[GitHub](https://github.com/digital-blueprint/submodule-pinning-action) | [GitHub Marketplace](https://github.com/marketplace/actions/submodule-pinning-check)

[![Test](https://github.com/digital-blueprint/submodule-pinning-action/actions/workflows/test.yml/badge.svg)](https://github.com/digital-blueprint/submodule-pinning-action/actions/workflows/test.yml)

A GitHub Action that verifies one or more git submodules are pinned to the
**exact commit** that a branch in the submodule's upstream repository currently
points to.

This is useful when a repository consumes another repository as a submodule and
a specific branch (for example `production`) must be the single source of truth
for what gets deployed. The action fails the workflow when a submodule is pinned
to a commit that differs from the tip of the configured upstream branch, so you
can use it to **gate deployments**.

## Features

- Check **multiple submodules** in a single step.
- Configure each submodule with its own **remote repository** and **remote branch**.
- Remote repository URL can be read automatically from `.gitmodules`.
- No submodule checkout required — it only reads the pinned commit from the tree
  and queries the remote with `git ls-remote` (fast, no clone).
- Rich job summary table and machine-readable outputs.

## Usage

```yaml
- uses: digital-blueprint/submodule-pinning-action@v1
  with:
    submodules: |
      vendor/signature = @production
      vendor/toolkit   = @main
```

Each line has the form:

```
<submodule-path> = <remote-repo-url>@<remote-branch>
```

If the remote repository URL is omitted (i.e. the line starts with `@`), the URL
is taken from the `.gitmodules` file of the checked-out repository:

```
vendor/signature = @production
```

Lines beginning with `#` are treated as comments.

### JSON configuration

You may also pass a JSON array, which is handy when the config is generated
dynamically:

```yaml
- uses: digital-blueprint/submodule-pinning-action@v1
  with:
    submodules: >-
      [
        {"path": "vendor/signature", "branch": "production"},
        {"path": "vendor/toolkit", "repo": "https://github.com/org/toolkit", "branch": "main"}
      ]
```

## Inputs

| Input               | Required | Default | Description                                                                                       |
| ------------------- | -------- | ------- | ------------------------------------------------------------------------------------------------- |
| `submodules`        | yes      | —       | Line-based or JSON list of submodules to check. See formats above.                                |
| `working-directory` | no       | `.`     | Directory of the git repository to inspect.                                                        |
| `fail-fast`         | no       | `false` | When `true`, stop at the first mismatch. When `false`, check every submodule and report them all. |

## Outputs

| Output       | Description                                                                          |
| ------------ | ------------------------------------------------------------------------------------ |
| `matched`    | JSON array of submodule paths whose pinned commit matches the upstream branch.       |
| `mismatched` | JSON array of submodule paths whose pinned commit does **not** match. Empty on pass. |

## Full example

```yaml
name: CI

on:
  push:
  pull_request:

jobs:
  check-submodule-pins:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        # Submodules do NOT need to be checked out; the action reads the
        # pinned commit from the repository tree directly.

      - uses: digital-blueprint/submodule-pinning-action@v1
        id: pins
        with:
          submodules: |
            vendor/signature = @production
            vendor/toolkit   = @production

      - name: Show result
        if: always()
        run: |
          echo "Matched:    ${{ steps.pins.outputs.matched }}"
          echo "Mismatched: ${{ steps.pins.outputs.mismatched }}"
```

## Gating a production deployment

A common use case is to only allow deployment from a `production` branch when
the submodules are pinned to the upstream `production` branch. Run the check as
a prerequisite job and make the deploy job depend on it:

```yaml
jobs:
  check-submodule-pins:
    if: github.ref == 'refs/heads/production'
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: digital-blueprint/submodule-pinning-action@v1
        with:
          submodules: |
            vendor/signature = @production

  deploy:
    needs: [check-submodule-pins]
    # Only block when we're on production; other branches skip the check.
    if: >-
      always() &&
      (github.ref != 'refs/heads/production' ||
       needs.check-submodule-pins.result == 'success')
    runs-on: ubuntu-latest
    steps:
      - run: ./deploy.sh
```

## How it works

For each configured submodule the action:

1. Reads the commit the submodule is pinned to via `git ls-tree HEAD -- <path>`
   (gitlink entries have mode `160000`).
2. Resolves the upstream repository URL, either from the configuration or from
   `.gitmodules`.
3. Fetches the tip of the configured branch with
   `git ls-remote <repo> refs/heads/<branch>`.
4. Compares the two commit SHAs and fails the workflow if they differ.

## Development / testing locally

The check is a plain bash script and can be run outside of GitHub Actions:

```bash
cd /path/to/your/repo
INPUT_SUBMODULES="vendor/signature = @production" \
  bash /path/to/submodule-pinning-action/check-submodule-pins.sh
```

## License

[MIT](./LICENSE)
