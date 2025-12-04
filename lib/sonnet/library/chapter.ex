defmodule Sonnet.Library.Chapter do
  use Ecto.Schema
  import Ecto.Changeset

  schema "chapters" do
    field :title, :string
    field :start_ms, :integer
    field :end_ms, :integer
    field :position, :integer

    belongs_to :book, Sonnet.Library.Book
    belongs_to :media_asset, Sonnet.Library.MediaAsset

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(chapter, attrs) do
    chapter
    |> cast(attrs, [:title, :start_ms, :end_ms, :position, :book_idk, :media_asset_id])
    |> validate_required([:title, :start_ms, :end_ms, :position, :book_id, :media_asset_id])
  end
end
