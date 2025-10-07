defmodule Sonnet.ContentTest do
  use Sonnet.DataCase

  alias Sonnet.Content

  describe "books" do
    alias Sonnet.Content.Book

    import Sonnet.AccountsFixtures, only: [user_scope_fixture: 0]
    import Sonnet.ContentFixtures

    @invalid_attrs %{name: nil, path: nil, bucket: nil}

    test "list_books/1 returns all scoped books" do
      scope = user_scope_fixture()
      other_scope = user_scope_fixture()
      book = book_fixture(scope)
      other_book = book_fixture(other_scope)
      assert Content.list_books(scope) == [book]
      assert Content.list_books(other_scope) == [other_book]
    end

    test "get_book!/2 returns the book with given id" do
      scope = user_scope_fixture()
      book = book_fixture(scope)
      other_scope = user_scope_fixture()
      assert Content.get_book!(scope, book.id) == book
      assert_raise Ecto.NoResultsError, fn -> Content.get_book!(other_scope, book.id) end
    end

    test "create_book/2 with valid data creates a book" do
      valid_attrs = %{name: "some name", path: "some path", bucket: "some bucket"}
      scope = user_scope_fixture()

      assert {:ok, %Book{} = book} = Content.create_book(scope, valid_attrs)
      assert book.name == "some name"
      assert book.path == "some path"
      assert book.bucket == "some bucket"
      assert book.user_id == scope.user.id
    end

    test "create_book/2 with invalid data returns error changeset" do
      scope = user_scope_fixture()
      assert {:error, %Ecto.Changeset{}} = Content.create_book(scope, @invalid_attrs)
    end

    test "update_book/3 with valid data updates the book" do
      scope = user_scope_fixture()
      book = book_fixture(scope)

      update_attrs = %{
        name: "some updated name",
        path: "some updated path",
        bucket: "some updated bucket"
      }

      assert {:ok, %Book{} = book} = Content.update_book(scope, book, update_attrs)
      assert book.name == "some updated name"
      assert book.path == "some updated path"
      assert book.bucket == "some updated bucket"
    end

    test "update_book/3 with invalid scope raises" do
      scope = user_scope_fixture()
      other_scope = user_scope_fixture()
      book = book_fixture(scope)

      assert_raise MatchError, fn ->
        Content.update_book(other_scope, book, %{})
      end
    end

    test "update_book/3 with invalid data returns error changeset" do
      scope = user_scope_fixture()
      book = book_fixture(scope)
      assert {:error, %Ecto.Changeset{}} = Content.update_book(scope, book, @invalid_attrs)
      assert book == Content.get_book!(scope, book.id)
    end

    test "delete_book/2 deletes the book" do
      scope = user_scope_fixture()
      book = book_fixture(scope)
      assert {:ok, %Book{}} = Content.delete_book(scope, book)
      assert_raise Ecto.NoResultsError, fn -> Content.get_book!(scope, book.id) end
    end

    test "delete_book/2 with invalid scope raises" do
      scope = user_scope_fixture()
      other_scope = user_scope_fixture()
      book = book_fixture(scope)
      assert_raise MatchError, fn -> Content.delete_book(other_scope, book) end
    end

    test "change_book/2 returns a book changeset" do
      scope = user_scope_fixture()
      book = book_fixture(scope)
      assert %Ecto.Changeset{} = Content.change_book(scope, book)
    end
  end
end
