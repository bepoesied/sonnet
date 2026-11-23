defmodule Sonnet.Test.AudioFixtures do
  @moduledoc """
  Generates tiny real audio files using `ffmpeg` for ingestion integration tests.
  """

  def generate_mp3!(dir, filename, opts \\ []) do
    duration_seconds = Keyword.get(opts, :duration_seconds, 1)
    freq = Keyword.get(opts, :frequency, 440)
    title = Keyword.get(opts, :title)
    artist = Keyword.get(opts, :artist)

    output_path = Path.join(dir, filename)

    metadata_args =
      []
      |> maybe_metadata("title", title)
      |> maybe_metadata("artist", artist)

    args =
      [
        "-f",
        "lavfi",
        "-i",
        "sine=frequency=#{freq}:duration=#{duration_seconds}",
        "-c:a",
        "libmp3lame",
        "-b:a",
        "64k"
      ] ++ metadata_args ++ ["-y", output_path]

    {output, 0} = System.cmd("ffmpeg", args, stderr_to_stdout: true)
    _ = output
    output_path
  end

  def generate_m4b!(dir, filename, opts \\ []) do
    duration_seconds = Keyword.get(opts, :duration_seconds, 2)
    chapters = Keyword.get(opts, :chapters, [])
    title = Keyword.get(opts, :title)
    artist = Keyword.get(opts, :artist)
    with_cover? = Keyword.get(opts, :with_cover, false)

    output_path = Path.join(dir, filename)

    base_audio = Path.join(dir, "base_#{Ecto.UUID.generate()}.m4a")

    {_, 0} =
      System.cmd(
        "ffmpeg",
        [
          "-f",
          "lavfi",
          "-i",
          "sine=frequency=440:duration=#{duration_seconds}",
          "-c:a",
          "aac",
          "-b:a",
          "64k",
          "-y",
          base_audio
        ],
        stderr_to_stdout: true
      )

    ffmeta_path = Path.join(dir, "meta_#{Ecto.UUID.generate()}.txt")

    chapter_lines =
      Enum.map_join(chapters, "\n", fn {ch_title, start_ms, end_ms} ->
        """
        [CHAPTER]
        TIMEBASE=1/1000
        START=#{start_ms}
        END=#{end_ms}
        title=#{ch_title}
        """
      end)

    header_lines =
      [
        ";FFMETADATA1",
        if(title, do: "title=#{title}"),
        if(artist, do: "artist=#{artist}")
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n")

    File.write!(ffmeta_path, header_lines <> "\n" <> chapter_lines)

    if with_cover? do
      cover_path = Path.join(dir, "cover_#{Ecto.UUID.generate()}.jpg")

      {_, 0} =
        System.cmd(
          "ffmpeg",
          [
            "-f",
            "lavfi",
            "-i",
            "color=c=blue:s=32x32:d=1",
            "-frames:v",
            "1",
            "-y",
            cover_path
          ],
          stderr_to_stdout: true
        )

      {_, 0} =
        System.cmd(
          "ffmpeg",
          [
            "-i",
            base_audio,
            "-i",
            cover_path,
            "-i",
            ffmeta_path,
            "-map",
            "0:a",
            "-map",
            "1:v",
            "-map_metadata",
            "2",
            "-c:a",
            "copy",
            "-c:v",
            "mjpeg",
            "-disposition:v:0",
            "attached_pic",
            "-f",
            "ipod",
            "-y",
            output_path
          ],
          stderr_to_stdout: true
        )
    else
      {_, 0} =
        System.cmd(
          "ffmpeg",
          [
            "-i",
            base_audio,
            "-i",
            ffmeta_path,
            "-map",
            "0:a",
            "-map_metadata",
            "1",
            "-c:a",
            "copy",
            "-f",
            "ipod",
            "-y",
            output_path
          ],
          stderr_to_stdout: true
        )
    end

    output_path
  end

  defp maybe_metadata(args, _key, nil), do: args
  defp maybe_metadata(args, key, val), do: args ++ ["-metadata", "#{key}=#{val}"]
end
