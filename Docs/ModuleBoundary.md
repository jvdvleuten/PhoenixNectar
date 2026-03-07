# Module Boundary Evaluation

Current package keeps one target (`PhoenixNectar`) for simplicity.

## Internal Architecture

- Actor core: `PhoenixClient`
- Value facade: `ChannelHandle`
- Transport boundary: `PhoenixTransport` + `URLSessionTransport`
- Typed protocol model: `PhoenixMessage`, `PhoenixValue`, `PhoenixEvent`

## Future split candidates

- `PhoenixNectarCore`: actor runtime + protocol model
- `PhoenixNectarTransportURLSession`: Foundation transport bridge
- `PhoenixNectar`: facade re-export target

Keeping a single target now keeps adoption friction low while API settles.
