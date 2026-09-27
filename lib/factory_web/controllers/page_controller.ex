defmodule FactoryWeb.PageController do
  use FactoryWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
