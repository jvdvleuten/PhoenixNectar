import PhoenixNectar

struct ConnectParams: Encodable, Sendable {
  let deviceID: String
}

func makeAuthenticatedClient(session: SessionStore, deviceIDStore: DeviceIDStore) throws -> Socket {
  try Socket(
    endpoint: "wss://api.example.com/socket",
    connectParamsProvider: {
      ConnectParams(deviceID: deviceIDStore.current())
    },
    authTokenProvider: {
      session.currentAccessToken()
    }
  )
}

protocol SessionStore {
  func currentAccessToken() -> String?
}

protocol DeviceIDStore {
  func current() -> String
}
