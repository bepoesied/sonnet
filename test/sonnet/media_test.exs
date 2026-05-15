defmodule Sonnet.MediaTest do
  use ExUnit.Case, async: true

  alias Sonnet.Media

  describe "file_hash/1" do
    test "returns a sha256 hash for a file" do
      path = Briefly.create!(type: :path)
      File.write!(path, "sonnet")

      assert Media.file_hash(path) ==
               "c9ad8f2cc1294afa0ef22fc2c019ff7243cdd272b2147ddca3f34c5036b05768"
    end
  end

  describe "merge_metadata/2" do
    test "prefers supplied metadata and falls back to probe metadata" do
      probe = %{
        "format" => %{
          "tags" => %{
            "title" => "Probe Title",
            "artist" => "Probe Author",
            "album_artist" => "Probe Narrator",
            "description" => "Probe Description"
          }
        }
      }

      assert Media.merge_metadata(%{"title" => "User Title", "author" => ""}, probe) == %{
               "title" => "User Title",
               "author" => "Probe Author",
               "narrator" => "Probe Narrator",
               "description" => "Probe Description"
             }
    end

    test "uses untitled fallback when neither source has a title" do
      assert Media.merge_metadata(%{}, %{})["title"] == "Untitled Book"
    end
  end

  describe "duration_ms_from_probe/1" do
    test "converts probe duration seconds to milliseconds" do
      assert Media.duration_ms_from_probe(%{"format" => %{"duration" => "1.234"}}) == 1234
    end

    test "returns zero for malformed probe output" do
      assert Media.duration_ms_from_probe(%{"format" => %{"duration" => "nope"}}) == 0
      assert Media.duration_ms_from_probe(%{}) == 0
    end
  end
end
