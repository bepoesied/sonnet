defmodule Sonnet.ContentFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `Sonnet.Content` context.
  """

  @doc """
  Generate a book.
  """
  def book_fixture(scope, attrs \\ %{}) do
    attrs =
      Enum.into(attrs, %{
        bucket: "some bucket",
        name: "some name",
        path: "some path"
      })

    {:ok, book} = Sonnet.Content.create_book(scope, attrs)
    book
  end
end
