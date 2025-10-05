defmodule SonnetWeb.PageController do
  use SonnetWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
