import OSLog
import PhoenixNectar

func installStructuredLogger(on client: Socket) async {
  let logger = Logger(subsystem: "com.example.chat", category: "phoenix")
  await client.setLogger(logger)
}

/*
 Representative Console output:

 info phoenix: transport: connect requested endpoint=ws://127.0.0.1:4000/socket
 info phoenix: transport: socket opened
 info phoenix: channel: join joinRef=1 topic=room:engineering
 debug phoenix: send: text frame sent event=phx_join ref=2 topic=room:engineering
 debug phoenix: receive: text frame received event=phx_reply ref=2 topic=room:engineering
 debug phoenix: channel: stale message dropped currentJoinRef=4 event=new_msg joinRef=3 topic=room:engineering
*/
