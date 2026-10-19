# mlops_course_repo

[![lint](https://github.com/anechytailenko/mlops_course_repo/actions/workflows/lint.yml/badge.svg)](https://github.com/anechytailenko/mlops_course_repo/actions/workflows/lint.yml)

Course project for **KSE MLOps — Introduction to MLOps and ML System Design**: a dynamic news classification system built on The Guardian Open Platform API, developed over five labs.

## Problem

Newsrooms file every article under a section, and doing it by hand is slow and inconsistent while topics and vocabulary change every week. This system suggests one or more sections for a news article (always at least one) from its full text and from metadata known at publication time, using The Guardian Open Platform API as its data source. It collects new articles daily, validates and versions them, keeps per-author features in a feature store, and trains, registers and serves a classifier. It monitors drift and quality and retrains when performance degrades, instead of relying on a model frozen in a notebook. Success means editors would accept at least 85% of suggestions, and every model can be rebuilt from the repository.

Design document: [`docs/design.md`](docs/design.md).

## Maturity scorecard

| Property | Evidence a reviewer checks | Added in |
|---|---|---|
| Repository reproducible from a clean clone | [CI is green](https://github.com/anechytailenko/mlops_course_repo/actions/workflows/lint.yml); `make setup` and `make lint` succeed on a fresh clone | Lab 1 |
| Design document exists and is current | [`docs/design.md`](docs/design.md) follows the template, every section filled or marked as an assumption | Lab 1 |

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
