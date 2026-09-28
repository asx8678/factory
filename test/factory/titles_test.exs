defmodule Factory.Runs.TitlesTest do
  use Factory.DataCase, async: false
  alias Factory.{Chat, Runs}
  alias Factory.Runs.Titles

  test "Kiro names a chat from what the person wrote" do
    {:ok, run} = Runs.create_run()
    Chat.handle(run, "Saving a draft sends me back to the login page")
    assert Titles.chat_message?(Runs.get_run(run.id))

    assert {:ok, run} = Titles.retitle(run.id)
    assert run.title == "Login redirect after draft save"
  end

  test "a title set with /rename is kept" do
    {:ok, run} = Runs.create_run()
    Chat.handle(run, "/rename Draft bug")
    run = Runs.get_run(run.id)
    refute Titles.chat_message?(run)
    assert {:error, :manual} = Titles.retitle(run.id)
    assert Runs.get_run(run.id).title == "Draft bug"
  end

  test "a chat stops being retitled after its first few messages" do
    {:ok, run} = Runs.create_run()
    for text <- ~w(one two three four), do: Chat.handle(run, text)
    refute Titles.chat_message?(Runs.get_run(run.id))
  end

  test "Kiro's reply is cleaned down to the title" do
    assert Titles.clean(~s(Title: "Dark mode toggle".\nMore text)) == "Dark mode toggle"
    assert Titles.clean("**Fix CSV export**") == "Fix CSV export"
  end
end
