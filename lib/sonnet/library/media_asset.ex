defmodule Sonnet.Library.MediaAsset do
  use Ecto.Schema
  import Ecto.Changeset

  schema "media_assets" do
    field :s3_key, :string

    has_many :chapters, Sonnet.Library.Chapter

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(media_asset, attrs \\ %{}) do
    media_asset
    |> cast(attrs, [:s3_key])
    |> validate_required([:s3_key])
    |> unique_constraint(:s3_key)
  end
end
