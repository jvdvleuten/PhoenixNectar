# Contributing

Thanks for contributing to PhoenixNectar.

## Setup

1. Install Swift 6.1+.
2. Clone the repo.
3. Run:

```bash
swift package resolve
swift test --parallel
```

## Development Rules

- Keep changes focused and reviewable.
- Preserve Swift 6 strict concurrency safety.
- Prefer typed APIs over stringly or untyped variants.
- Add or adjust tests for behavior changes.
- Keep public API changes documented in `Docs/API-Reference.md` and `README.md`.
- Use event-driven test synchronization (streams) instead of polling or `Task.sleep`.

## Pull Requests

- Include a short problem statement and what changed.
- Link relevant issue(s) when available.
- Ensure CI is green.
- Update `CHANGELOG.md` for user-visible changes.

## Running E2E Tests

See [e2e/README.md](./e2e/README.md) for instructions on running the Phoenix-backed integration tests.
