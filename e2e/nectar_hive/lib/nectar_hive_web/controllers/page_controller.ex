defmodule NectarHiveWeb.PageController do
  use NectarHiveWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
