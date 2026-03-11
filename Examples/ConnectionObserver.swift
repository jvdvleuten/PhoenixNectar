import PhoenixNectar

func observeClient(_ client: Socket) async {
  await client.setMetricsHook { event in
    print("metric:", event)
  }

  let stream = await client.connectionStateStream()
  for await state in stream {
    print("state:", state)
  }
}
