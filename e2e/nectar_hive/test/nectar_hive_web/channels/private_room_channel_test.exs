defmodule NectarHiveWeb.PrivateRoomChannelTest do
  use NectarHiveWeb.ChannelCase

  test "allows different authenticated users to join the same room and rejects invalid topics" do
    {:ok, _, socket_a} =
      NectarHiveWeb.UserSocket
      |> socket("socket-1", %{user_id: "user-a", device_id: "device-a"})
      |> subscribe_and_join(NectarHiveWeb.PrivateRoomChannel, "private:room:engineering")

    assert socket_a.topic == "private:room:engineering"

    {:ok, _, socket_b} =
      NectarHiveWeb.UserSocket
      |> socket("socket-2", %{user_id: "user-b", device_id: "device-b"})
      |> subscribe_and_join(NectarHiveWeb.PrivateRoomChannel, "private:room:engineering")

    assert socket_b.topic == "private:room:engineering"

    assert {:error, %{reason: "invalid_topic"}} =
             NectarHiveWeb.UserSocket
             |> socket("socket-3", %{user_id: "user-c", device_id: "device-c"})
             |> subscribe_and_join(NectarHiveWeb.PrivateRoomChannel, "private:room:")
  end

  test "message:send broadcasts message:posted and replies with message_id" do
    {:ok, _, socket} =
      NectarHiveWeb.UserSocket
      |> socket("socket-1", %{user_id: "user-a", device_id: "device-a"})
      |> subscribe_and_join(NectarHiveWeb.PrivateRoomChannel, "private:room:engineering")

    ref = push(socket, "message:send", %{"body" => "hello"})
    assert_reply ref, :ok, %{"accepted" => true, "message_id" => message_id} when is_binary(message_id)

    assert_broadcast "message:posted", %{
      "id" => ^message_id,
      "from_user_id" => "user-a",
      "body" => "hello",
      "sent_at" => sent_at
    }

    assert is_binary(sent_at)
  end

  test "binary:upload replies with size and broadcasts image bytes" do
    {:ok, _, socket} =
      NectarHiveWeb.UserSocket
      |> socket("socket-1", %{user_id: "user-a", device_id: "device-a"})
      |> subscribe_and_join(NectarHiveWeb.PrivateRoomChannel, "private:room:engineering")

    data = <<0, 1, 2, 3, 255>>
    ref = push(socket, "binary:upload", data)
    assert_reply ref, :ok, %{"accepted" => true, "size" => 5}
    assert_broadcast "image:posted", {:binary, ^data}
  end

  test "message:send is broadcast to other users in the same room" do
    {:ok, _, sender} =
      NectarHiveWeb.UserSocket
      |> socket("socket-1", %{user_id: "user-a", device_id: "device-a"})
      |> subscribe_and_join(NectarHiveWeb.PrivateRoomChannel, "private:room:engineering")

    {:ok, _, _receiver} =
      NectarHiveWeb.UserSocket
      |> socket("socket-2", %{user_id: "user-b", device_id: "device-b"})
      |> subscribe_and_join(NectarHiveWeb.PrivateRoomChannel, "private:room:engineering")

    ref = push(sender, "message:send", %{"body" => "hello team"})
    assert_reply ref, :ok, %{"accepted" => true}
    assert_broadcast "message:posted", %{"from_user_id" => "user-a", "body" => "hello team"}
  end
end
