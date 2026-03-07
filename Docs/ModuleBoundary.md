# Module Boundary Evaluation

Current package keeps one target (`PhoenixNectar`) for ease of adoption.

## Candidate split (future)

- `PhoenixNectarCore`
  - frame codec
  - payload/event/status types
  - timers/scheduler abstractions
- `PhoenixNectarTransportURLSession`
  - `URLSessionTransport` bridge
- `PhoenixNectar`
  - facade + convenience exports

## Why not split now

- API is still settling during Swift 6 modernization.
- A split now would add migration churn without clear external benefit yet.
- Existing test matrix is simpler with one target.

Re-evaluate split once public API has at least one stable release cycle.
