defmodule SonnetWeb.PageController do
  use SonnetWeb, :controller

  def home(conn, _params) do
    if conn.assigns.current_scope.user do
      redirect(conn, to: ~p"/library")
    else
      render(conn, :home)
    end
  end
end
