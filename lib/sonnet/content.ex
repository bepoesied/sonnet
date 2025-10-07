defmodule Sonnet.Content do
  @moduledoc """
  The Content context.
  """

  import Ecto.Query, warn: false
  alias Sonnet.Repo

  alias Sonnet.Content.Book

  def list_books() do
    Repo.all(Book)
  end

  def get_book!(id) do
    Repo.get_by!(Book, id: id)
  end

  def create_book(attrs) do
    %Book{}
    |> Book.changeset(attrs)
    |> Repo.insert()
  end

  def update_book(%Book{} = book, attrs) do
    book
    |> Book.changeset(attrs)
    |> Repo.update()
  end

  def delete_book(%Book{} = book) do
    Repo.delete(book)
  end

  def change_book(%Book{} = book, attrs \\ %{}) do
    Book.changeset(book, attrs)
  end

  def ingest_books(books) do
    {_count, books} =
      Repo.insert_all(Book, books,
        on_conflict: {:replace_all_except, [:id, :inserted_at]},
        conflict_target: :name,
        returning: true
      )

    books = Enum.map(books, & &1.id)

    Repo.delete_all(from b in Book, where: b.id not in ^books)
  end
end
