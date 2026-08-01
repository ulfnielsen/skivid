import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from resize_video import collect_video_files, resize_videos


class TestCollectVideoFiles(unittest.TestCase):
    def test_recursively_collects_videos_case_insensitively(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            source = Path(tmpdir) / "organized"
            athlete = source / "2026-07-16_Neuss" / "Idun Nielsen"
            athlete.mkdir(parents=True)
            clip = athlete / "C0071.MP4"
            clip.write_text("video")
            (athlete / "notes.txt").write_text("notes")

            self.assertEqual(collect_video_files([source]), [clip])

    def test_skips_generated_outputs_during_directory_scan(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            source = Path(tmpdir)
            original = source / "run.mov"
            original.write_text("video")
            (source / "run_resized.mov").write_text("resized")

            self.assertEqual(collect_video_files([source]), [original])

    def test_deduplicates_overlapping_inputs(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            source = Path(tmpdir)
            clip = source / "clip.mp4"
            clip.write_text("video")

            self.assertEqual(collect_video_files([source, clip]), [clip])

    def test_keeps_explicit_files_with_unusual_extensions(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            clip = Path(tmpdir) / "camera.transport"
            clip.write_text("video")

            self.assertEqual(collect_video_files([clip]), [clip])

    @patch("resize_video._probe_duration", return_value=None)
    @patch("resize_video._run_ffmpeg")
    def test_directory_outputs_to_mirrored_sibling(
        self, run_ffmpeg, _probe_duration
    ) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            source = Path(tmpdir) / "organized"
            clip = source / "2026-07-16_Neuss" / "Idun Nielsen" / "C0071.MP4"
            clip.parent.mkdir(parents=True)
            clip.write_text("original")

            def write_output(_input_path, output_path, _filter_chain, **_kwargs):
                output_path.write_text("resized")

            run_ffmpeg.side_effect = write_output

            results = resize_videos([source])
            expected = (
                Path(tmpdir)
                / "organized_resize"
                / "2026-07-16_Neuss"
                / "Idun Nielsen"
                / "C0071.MP4"
            )

            self.assertEqual([result.output for result in results], [expected])
            self.assertEqual(expected.read_text(), "resized")
            self.assertEqual(clip.read_text(), "original")

    @patch("resize_video._probe_duration", return_value=None)
    @patch("resize_video._run_ffmpeg")
    def test_explicit_file_keeps_adjacent_resized_output(
        self, run_ffmpeg, _probe_duration
    ) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            clip = Path(tmpdir) / "clip.mp4"
            clip.write_text("original")
            run_ffmpeg.side_effect = (
                lambda _input, output, _filters, **_kwargs: output.write_text("resized")
            )

            result = resize_videos([clip])[0]

            self.assertEqual(result.output, Path(tmpdir) / "clip_resized.mp4")


if __name__ == "__main__":  # pragma: no cover
    unittest.main()
