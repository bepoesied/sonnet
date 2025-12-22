defmodule Sonnet.Library.ListenProgress do
  use Ecto.Schema
  import Ecto.Changeset

  schema "listen_progresses" do
    field :offset_ms, :integer

    belongs_to :book, Sonnet.Library.Book
    belongs_to :user, Sonnet.Accounts.User
    belongs_to :chapter, Sonnet.Library.Chapter

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(listen_progress, attrs) do
    listen_progress
    |> cast(attrs, [:offset_ms, :user_id, :book_id, :chapter_id])
    |> validate_required([:offset_ms, :user_id, :book_id, :chapter_id])
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:book_id)
    |> foreign_key_constraint(:chapter_id)
    |> unique_constraint([:user_id, :book_id])
  end
end
