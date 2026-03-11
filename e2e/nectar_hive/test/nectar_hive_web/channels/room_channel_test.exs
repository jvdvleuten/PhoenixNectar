defmodule NectarHiveWeb.RoomChannelTest do
  use NectarHiveWeb.ChannelCase

  setup do
    {:ok, _, socket} =
      NectarHiveWeb.UserSocket
      |> socket("user_id", %{some: :assign})
      |> subscribe_and_join(NectarHiveWeb.RoomChannel, "room:lobby")

    %{socket: socket}
  end

  test "new_msg replies and broadcasts", %{socket: socket} do
    ref = push(socket, "new_msg", %{"body" => "hi"})
    assert_reply ref, :ok, %{"accepted" => true, "echo" => "hi"}
    assert_broadcast "new_msg", %{"body" => "hi"}
  end

  test "create replies with deterministic id", %{socket: socket} do
    ref = push(socket, "create", %{"body" => "x"})
    assert_reply ref, :ok, %{"id" => id} when is_integer(id)
  end

  test "generic event echoes and broadcasts", %{socket: socket} do
    ref = push(socket, "new_event", %{"value" => 1})
    assert_reply ref, :ok, %{"value" => 1}
    assert_broadcast "new_event", %{"value" => 1}
  end
end
