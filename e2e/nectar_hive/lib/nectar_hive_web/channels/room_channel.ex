defmodule NectarHiveWeb.RoomChannel do
  use NectarHiveWeb, :channel

  @impl true
  def join("room:lobby", payload, socket) do
    if authorized?(payload) do
      {:ok, socket}
    else
      {:error, %{reason: "unauthorized"}}
    end
  end

  @impl true
  def handle_in("new_msg", %{"body" => body} = payload, socket) do
    broadcast(socket, "new_msg", payload)
    {:reply, {:ok, %{"accepted" => true, "echo" => body}}, socket}
  end

  @impl true
  def handle_in("create", %{"body" => body}, socket) do
    {:reply, {:ok, %{"id" => :erlang.phash2(body)}}, socket}
  end

  @impl true
  def handle_in(event, payload, socket) when is_binary(event) and is_map(payload) do
    broadcast(socket, event, payload)
    {:reply, {:ok, payload}, socket}
  end

  defp authorized?(_payload) do
    true
  end
end
