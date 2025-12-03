defmodule Sonnet.Library.Chapter do
  use Ecto.Schema
  import Ecto.Changeset

  schema "chapters" do
    field :title, :string
    field :start_ms, :integer
    field :end_ms, :integer
    field :position, :integer
    field :book_id, :id

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(chapter, attrs) do
    chapter
    |> cast(attrs, [:title, :start_ms, :end_ms, :position, :book_id])
    |> validate_required([:title, :start_ms, :end_ms, :position, :book_id])
  end
end
