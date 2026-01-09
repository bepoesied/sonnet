defmodule Sonnet.Library.Chapter do
  use Ecto.Schema
  import Ecto.Changeset

  schema "chapters" do
    field :title, :string
    field :start_ms, :integer
    field :end_ms, :integer
    field :duration_ms, :integer
    field :position, :integer

    belongs_to :book, Sonnet.Library.Book
    belongs_to :media_asset, Sonnet.Library.MediaAsset

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(chapter, attrs \\ %{}) do
    chapter
    |> cast(attrs, [
      :title,
      :start_ms,
      :end_ms,
      :duration_ms,
      :position,
      :book_id,
      :media_asset_id
    ])
    |> validate_required([
      :title,
      :start_ms,
      :end_ms,
      :duration_ms,
      :position,
      :book_id,
      :media_asset_id
    ])
    |> validate_number(:start_ms, greater_than_or_equal_to: 0)
    |> validate_number(:end_ms, greater_than_or_equal_to: 0)
    |> validate_number(:duration_ms, greater_than_or_equal_to: 0)
    |> validate_chapter_timing()
  end

  defp validate_chapter_timing(changeset) do
    start_ms = get_field(changeset, :start_ms)
    end_ms = get_field(changeset, :end_ms)
    duration_ms = get_field(changeset, :duration_ms)

    cond do
      is_nil(start_ms) or is_nil(end_ms) or is_nil(duration_ms) ->
        changeset

      true ->
        expected_end_ms = start_ms + duration_ms

        if end_ms == expected_end_ms do
          changeset
        else
          add_error(
            changeset,
            :end_ms,
            "end_ms must equal start_ms + duration_ms (expected #{expected_end_ms}, got #{end_ms})"
          )
        end
    end
  end
end
