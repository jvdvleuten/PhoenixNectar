import {Socket} from "phoenix"

const endpointInput = document.querySelector("#endpoint")
const userInput = document.querySelector("#user")
const roomInput = document.querySelector("#room")
const bodyInput = document.querySelector("#body")
const connectButton = document.querySelector("#connect")
const sendButton = document.querySelector("#send")
const messages = document.querySelector("#messages")

let socket = null
let channel = null

const log = (line) => {
  const div = document.createElement("div")
  div.textContent = line
  messages.appendChild(div)
}

connectButton.addEventListener("click", () => {
  const endpoint = endpointInput.value
  const userID = userInput.value
  const roomID = roomInput.value
  const token = `user:${userID}`

  socket?.disconnect()

  socket = new Socket(endpoint, {
    authToken: token,
    params: {device_id: "web-demo"}
  })

  socket.connect()

  const topic = `private:room:${roomID}`
  channel = socket.channel(topic, {})

  channel.on("message:posted", (payload) => {
    log(`${payload.from_user_id}: ${payload.body}`)
  })

  channel.join()
    .receive("ok", () => log(`joined ${topic}`))
    .receive("error", (reason) => log(`join failed: ${JSON.stringify(reason)}`))
})

sendButton.addEventListener("click", () => {
  if(!channel) return
  const body = bodyInput.value
  channel.push("message:send", {body})
    .receive("ok", (reply) => log(`sent ${reply.message_id}`))
    .receive("error", (reason) => log(`send failed: ${JSON.stringify(reason)}`))
})
