defmodule Sonnet.Library.Book do
  use Ecto.Schema
  import Ecto.Changeset

  schema "books" do
    field :title, :string
    field :author, :string
    field :narrator, :string
    field :description, :string
    field :cover_s3_key, :string

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(book, attrs) do
    book
    |> cast(attrs, [:title, :author, :narrator, :description, :cover_s3_key])
    |> validate_required([:title])
  end
end
