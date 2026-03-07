# Actor Rewrite TODO (v0.1)

1. [x] `PhoenixClient` actor as single mutable runtime owner
2. [x] `ChannelHandle` Sendable value type API
3. [x] AsyncSequence-first events/messages API
4. [x] Typed event/payload model (`PhoenixEvent`, `PhoenixValue`, `PhoenixMessage`)
5. [x] Typed push request/response decode API
6. [x] Transport isolation boundary (`PhoenixTransport` + URLSession bridge)
7. [x] Cohesive typed error model (`PhoenixError`)
8. [x] Swift Testing actor-first test suite update
