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
  def changeset(chapter, attrs \\ %{}) do
    chapter
    |> cast(attrs, [:title, :start_ms, :end_ms, :position, :book_id, :media_asset_id])
    |> validate_required([:title, :start_ms, :end_ms, :position, :book_id, :media_asset_id])
    |> validate_number(:start_ms, greater_than_or_equal_to: 0)
    |> validate_number(:end_ms, greater_than: 0)
    |> validate_greater_than(:end_ms, :start_ms)
  end

  defp validate_greater_than(changeset, field, other_field) do
    value = get_field(changeset, field)
    other_value = get_field(changeset, other_field)

    cond do
      is_nil(value) or is_nil(other_value) ->
        changeset

      value > other_value ->
        changeset

      true ->
        add_error(
          changeset,
          field,
          "#{field} must be greater than #{other_field}"
        )
    end
  end
end
