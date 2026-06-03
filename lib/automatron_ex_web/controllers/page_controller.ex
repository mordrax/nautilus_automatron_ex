defmodule AutomatronExWeb.PageController do
  use AutomatronExWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
