defmodule Sonnet.Content.Book do
  use Ecto.Schema
  import Ecto.Changeset

  schema "books" do
    field :name, :string
    field :bucket, :string
    field :path, :string

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(book, attrs) do
    book
    |> cast(attrs, [:name, :bucket, :path])
    |> validate_required([:name, :bucket, :path])
  end
end
