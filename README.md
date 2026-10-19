# mlops_course_repo

[![lint](https://github.com/anechytailenko/mlops_course_repo/actions/workflows/lint.yml/badge.svg)](https://github.com/anechytailenko/mlops_course_repo/actions/workflows/lint.yml)

Course project for **KSE MLOps — Introduction to MLOps and ML System Design**: a dynamic news classification system, built over five labs.

> The problem statement (five sentences) and the maturity scorecard are added as part of Lab 1.

## Quick start

Requirements: Python ≥ 3.12, [uv](https://docs.astral.sh/uv/), `make`.

```bash
git clone https://github.com/anechytailenko/mlops_course_repo.git
cd mlops_course_repo
make setup    # uv sync: installs the pinned environment from uv.lock
make lint     # uv run ruff check .
```

## Continuous integration

Every push and pull request runs the workflow [`.github/workflows/lint.yml`](.github/workflows/lint.yml) on a clean `ubuntu-latest` runner:

| Step | What it does |
|---|---|
| `actions/checkout@v4` | Checks out the repository |
| `astral-sh/setup-uv@v5` | Installs uv |
| `make setup` | Recreates the exact environment from `pyproject.toml`, `uv.lock` and `.python-version` |
| `make lint` | Runs ruff over the whole repository; any lint error fails the run |

A green badge above means a fresh clone can be set up and linted with the two commands from *Quick start*. Lab 2 extends CI with tests.

Check runs: the **Actions** tab on GitHub, or from the terminal:

```bash
gh run list --workflow lint.yml   # recent runs and their status
gh run watch                      # follow the current run
gh run view --log-failed          # logs of failed steps
```

## Pre-commit

The same linter runs locally before each commit, so errors are caught before CI. The hook in [`.pre-commit-config.yaml`](.pre-commit-config.yaml) calls `uv run ruff check`, so it uses the ruff version pinned in `uv.lock`, the same one CI uses.

```bash
uv run pre-commit install          # once per clone
uv run pre-commit run --all-files  # run manually on all files
```

## Repository layout

```
.github/workflows/lint.yml   # CI: make setup && make lint on push and PR
.pre-commit-config.yaml      # ruff before each commit
Makefile                     # setup, lint
pyproject.toml, uv.lock      # dependencies and pinned versions
.python-version              # Python version used by uv
```
