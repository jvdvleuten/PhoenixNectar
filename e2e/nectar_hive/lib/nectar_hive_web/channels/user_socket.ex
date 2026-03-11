defmodule NectarHiveWeb.UserSocket do
  use Phoenix.Socket

  channel "room:*", NectarHiveWeb.RoomChannel
  channel "private:room:*", NectarHiveWeb.PrivateRoomChannel

  @impl true
  def connect(params, socket, connect_info) do
    token = Map.get(connect_info, :auth_token)
    device_id = Map.get(params, "device_id")

    case parse_user_id(token) do
      {:ok, user_id} ->
        {:ok,
         socket
         |> assign(:user_id, user_id)
         |> assign(:device_id, device_id)}

      :error ->
        :error
    end
  end

  @impl true
  def id(_socket), do: nil

  defp parse_user_id("user:" <> user_id), do: {:ok, String.downcase(user_id)}
  defp parse_user_id(_), do: :error
end
