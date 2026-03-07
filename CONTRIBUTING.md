# Contributing

Thanks for contributing to PhoenixNectar.

## Setup

1. Install Swift 6.2+.
2. Clone the repo.
3. Run:

```bash
swift package resolve
swift test --parallel
```

## Development Rules

- Keep changes focused and reviewable.
- Preserve Swift 6 concurrency safety.
- Prefer typed APIs over stringly or untyped variants.
- Add/adjust tests for behavior changes.
- Keep public API changes documented in `Docs/` and `README.md`.

## Pull Requests

- Include a short problem statement and what changed.
- Link relevant issue(s) when available.
- Ensure CI is green.
- Update `CHANGELOG.md` for user-visible changes.
