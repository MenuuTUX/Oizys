# Changelog

## Unreleased

- Use `Oizys.png` for repository branding and native macOS app icons.
- Measure Python tools and separately compiled native tests alongside instrumented
  production, debug, CLI, and developer executables. Keep untested code in the denominator.
- Add a strict project coverage check and reject invalid coverage thresholds.
- Load the requested library configuration in normal test runs and fail builds by exit status.
- Remove temporary configuration directories when tests exit. Keep production logging
  arguments type-checked without evaluating them or emitting log calls.
- Test installation replacement/rollback, build policy validation, icon packaging, CLI
  validation, and native diagnostic exports.
- Update contributor guidance and document coverage and hardware-validation limitations.

## 0.3.0

Current source version. Includes the Oizys rename, production/debug workflows, and the
Ridge per-head mode-addressing fixes in commit `6d975ad`. See
[the protocol notes](Documentation/Protocol.md) for the wire-format corrections.
