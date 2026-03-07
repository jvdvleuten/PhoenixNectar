# Changelog

All notable changes to this project will be documented in this file.

The format is based on Keep a Changelog, and this project follows Semantic Versioning.

## [Unreleased]

## [0.1.0] - 2026-03-07

### Added
- Swift 6 package (`swift-tools-version: 6.2`) for iOS 18+, macOS 15+, tvOS 18+, watchOS 11+.
- Concurrency-first APIs with `AsyncStream` and async channel/push operations.
- Typed payload model via `PhoenixValue` and typed event/status helpers.
- Structured logging protocol (`PhoenixLogger`).
- Injectable scheduling abstraction (`PhoenixScheduler`) for deterministic tests.
- Swift Testing-based unit test suite and CI workflow (Linux + macOS).
- Public docs (`PublicAPI`, `Compatibility`, `ModuleBoundary`).

### Changed
- Ported/modernized from SwiftPhoenixClient semantics to Swift 6-native patterns.
- Transport uses async WebSocket send/receive where Foundation supports it.

[Unreleased]: https://github.com/jvdvleuten/PhoenixNectar/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/jvdvleuten/PhoenixNectar/releases/tag/v0.1.0
