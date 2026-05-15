defmodule SonnetWeb.API.MeController do
  use SonnetWeb, :controller

  def show(conn, _params) do
    user = conn.assigns.current_scope.user

    json(conn, %{
      id: user.id,
      name: user.name,
      avatar_url: user.avatar_url
    })
  end
end
