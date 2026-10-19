.PHONY: setup lint

setup:
	uv sync

lint:
	uv run ruff check .
