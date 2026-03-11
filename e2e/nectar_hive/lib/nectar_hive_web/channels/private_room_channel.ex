defmodule NectarHiveWeb.PrivateRoomChannel do
  use NectarHiveWeb, :channel

  @impl true
  def join("private:room:" <> room_id, _payload, socket) when room_id != "" do
    {:ok, assign(socket, :room_id, room_id)}
  end

  def join("private:room:", _payload, _socket) do
    {:error, %{reason: "invalid_topic"}}
  end

  @impl true
  def handle_in("message:send", %{"body" => body}, socket) when is_binary(body) do
    message = %{
      "id" => Integer.to_string(System.unique_integer([:positive])),
      "from_user_id" => socket.assigns.user_id,
      "body" => body,
      "sent_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    }

    broadcast(socket, "message:posted", message)
    {:reply, {:ok, %{"message_id" => message["id"], "accepted" => true}}, socket}
  end

  @impl true
  def handle_in("binary:upload", {:binary, payload}, socket) when is_binary(payload) do
    size = byte_size(payload)
    broadcast(socket, "image:posted", {:binary, payload})
    {:reply, {:ok, %{"accepted" => true, "size" => size}}, socket}
  end

  @impl true
  def handle_in("binary:upload", payload, socket) when is_binary(payload) do
    size = byte_size(payload)
    broadcast(socket, "image:posted", {:binary, payload})
    {:reply, {:ok, %{"accepted" => true, "size" => size}}, socket}
  end
end
