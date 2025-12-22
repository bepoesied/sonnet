defmodule SonnetWeb.HealthCheckController do
  use SonnetWeb, :controller

  def index(conn, _params) do
    text(conn, "ok")
  end
end
