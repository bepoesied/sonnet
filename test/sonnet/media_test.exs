defmodule Sonnet.MediaTest do
  use ExUnit.Case, async: true

  alias Sonnet.Media
  alias Sonnet.Test.AudioFixtures

  describe "file_hash/1" do
    test "returns a sha256 hash for a file" do
      path = Briefly.create!(type: :path)
      File.write!(path, "sonnet")

      assert Media.file_hash(path) ==
               "c9ad8f2cc1294afa0ef22fc2c019ff7243cdd272b2147ddca3f34c5036b05768"
    end
  end

  describe "with_temp_dir/1" do
    test "removes the temporary directory after normal completion and after exceptions" do
      parent = self()

      Media.with_temp_dir(fn dir ->
        send(parent, {:dir, dir})
        File.write!(Path.join(dir, "file.txt"), "hello")
        assert File.dir?(dir)
      end)

      assert_receive {:dir, dir}
      refute File.exists?(dir)

      assert_raise RuntimeError, "boom", fn ->
        Media.with_temp_dir(fn err_dir ->
          send(parent, {:err_dir, err_dir})
          File.write!(Path.join(err_dir, "file.txt"), "hello")
          raise "boom"
        end)
      end

      assert_receive {:err_dir, err_dir}
      refute File.exists?(err_dir)
    end
  end

  describe "merge_metadata/3" do
    test "prefers supplied metadata, falls back to probe (case-insensitive), then fallback title" do
      probe = %{
        "format" => %{
          "tags" => %{
            "TITLE" => "Probe Title",
            "artist" => "Probe Author",
            "album_artist" => "Probe Narrator",
            "description" => "Probe Description"
          }
        }
      }

      assert Media.merge_metadata(%{"title" => "User Title", "author" => "   "}, probe) == %{
               "title" => "User Title",
               "author" => "Probe Author",
               "narrator" => "Probe Narrator",
               "description" => "Probe Description"
             }

      assert Media.merge_metadata(%{}, %{}, "Filename Fallback")["title"] == "Filename Fallback"
    end

    test "prefers album over title when prefer_album: true is set" do
      probe = %{
        "format" => %{
          "tags" => %{
            "title" => "Chapter 1",
            "album" => "Book Album Title"
          }
        }
      }

      assert Media.merge_metadata(%{}, probe, nil, prefer_album: true)["title"] ==
               "Book Album Title"

      assert Media.merge_metadata(%{}, probe)["title"] == "Chapter 1"
    end

    test "uses untitled fallback when no source has a title" do
      assert Media.merge_metadata(%{}, %{})["title"] == "Untitled Book"
    end
  end

  describe "duration_ms_from_probe/1 and parse_duration_ms/1" do
    test "converts float and integer duration strings to milliseconds" do
      assert Media.duration_ms_from_probe(%{"format" => %{"duration" => "1.234"}}) == 1234
      assert Media.duration_ms_from_probe(%{"format" => %{"duration" => "120"}}) == 120_000
      assert {:ok, 120_000} = Media.parse_duration_ms(%{"format" => %{"duration" => "120"}})
    end

    test "rejects malformed or non-positive probe durations" do
      assert Media.duration_ms_from_probe(%{"format" => %{"duration" => "nope"}}) == 0
      assert Media.duration_ms_from_probe(%{}) == 0

      assert {:error, {:permanent, :invalid_duration}} =
               Media.parse_duration_ms(%{"format" => %{"duration" => "0"}})

      assert {:error, {:permanent, :invalid_duration}} =
               Media.parse_duration_ms(%{"format" => %{"duration" => "nope"}})
    end
  end

  describe "natural_sort_key/1" do
    test "sorts numeric chapter filenames naturally" do
      filenames = ["Chapter 10.mp3", "Chapter 2.mp3", "Chapter 1.mp3", "chapter 20.mp3"]

      assert Enum.sort_by(filenames, &Media.natural_sort_key/1) == [
               "Chapter 1.mp3",
               "Chapter 2.mp3",
               "Chapter 10.mp3",
               "chapter 20.mp3"
             ]
    end
  end

  describe "segment_file/3" do
    test "segments a chaptered m4b using fast input seeking and preserves chapter titles" do
      Media.with_temp_dir(fn work_dir ->
        source =
          AudioFixtures.generate_m4b!(work_dir, "book.m4b",
            duration_seconds: 2,
            chapters: [{"Opening", 0, 1000}, {"Closing", 1000, 2000}]
          )

        assert {:ok, probe} = Media.probe_file(source)
        assert Media.has_audio_stream?(probe)
        assert {:ok, segments} = Media.segment_file(source, probe, work_dir)
        assert [first, second] = segments
        assert first.title == "Opening"
        assert second.title == "Closing"
        assert File.exists?(first.path)
        assert File.exists?(second.path)
      end)
    end

    test "skips zero-duration chapter markers instead of failing segmentation" do
      Media.with_temp_dir(fn work_dir ->
        source = AudioFixtures.generate_m4b!(work_dir, "markers.m4b", duration_seconds: 2)

        probe = %{
          "format" => %{"format_name" => "mov,mp4,m4a,3gp,3g2,mj2"},
          "chapters" => [
            %{"start_time" => "0.0", "end_time" => "2.0", "tags" => %{"title" => "Main"}},
            %{"start_time" => "2.0", "end_time" => "2.0", "tags" => %{"title" => "Empty Marker"}}
          ]
        }

        assert {:ok, [segment]} = Media.segment_file(source, probe, work_dir)
        assert segment.title == "Main"
        assert File.exists?(segment.path)
      end)
    end

    test "segments an unchaptered m4b by duration" do
      Media.with_temp_dir(fn work_dir ->
        source = AudioFixtures.generate_m4b!(work_dir, "plain.m4b", duration_seconds: 1)

        assert {:ok, probe} = Media.probe_file(source)
        assert {:ok, [segment]} = Media.segment_file(source, probe, work_dir)
        assert segment.title == nil
        assert File.exists?(segment.path)
      end)
    end
  end
end
