import tempfile
import unittest
from pathlib import Path

from upload_to_drive import plan_drive_uploads


class TestPlanDriveUploads(unittest.TestCase):
    def test_plan_writes_athlete_first_structure(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            base = Path(tmpdir)
            source = base / "organized"
            dest = base / "drive"
            dest.mkdir()

            (source / "2025-12-13_Zurs" / "Alice").mkdir(parents=True)
            (source / "2025-12-13_Zurs" / "Bob").mkdir(parents=True)
            (source / "2025-12-15_Zurs" / "Alice").mkdir(parents=True)

            (source / "2025-12-13_Zurs" / "Alice" / "run1.mp4").write_text("alice-1")
            (source / "2025-12-13_Zurs" / "Bob" / "clip.mov").write_text("bob-clip")
            (source / "2025-12-15_Zurs" / "Alice" / "run2.m4v").write_text("alice-2")
            (source / "2025-12-13_Zurs" / "Alice" / "notes.txt").write_text("skip-me")

            plan = plan_drive_uploads(source)
            self.assertEqual(len(plan), 3, "Only video files should be planned by default")

            for entry in plan:
                target = dest / entry.athlete / entry.event / entry.local_path.name
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text(entry.local_path.read_text())

            self.assertTrue((dest / "Alice" / "2025-12-13_Zurs" / "run1.mp4").exists())
            self.assertTrue((dest / "Alice" / "2025-12-15_Zurs" / "run2.m4v").exists())
            self.assertTrue((dest / "Bob" / "2025-12-13_Zurs" / "clip.mov").exists())
            self.assertFalse((dest / "Alice" / "2025-12-13_Zurs" / "notes.txt").exists())

            seen = set()
            for athlete_dir in dest.iterdir():
                for event_dir in athlete_dir.iterdir():
                    for file_path in event_dir.iterdir():
                        if file_path.is_file():
                            seen.add((athlete_dir.name, event_dir.name, file_path.name))

            expected = {
                ("Alice", "2025-12-13_Zurs", "run1.mp4"),
                ("Alice", "2025-12-15_Zurs", "run2.m4v"),
                ("Bob", "2025-12-13_Zurs", "clip.mov"),
            }
            self.assertEqual(seen, expected)

    def test_plan_handles_event_root_directory(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            base = Path(tmpdir)
            event_dir = base / "2025-12-20_Training"
            (event_dir / "Alice").mkdir(parents=True)
            (event_dir / "Bob").mkdir(parents=True)

            (event_dir / "Alice" / "gopro.mp4").write_text("alice")
            (event_dir / "Bob" / "rear.mov").write_text("bob")

            plan = plan_drive_uploads(event_dir)
            destinations = {(entry.athlete, entry.event, entry.local_path.name) for entry in plan}

            expected = {
                ("Alice", "2025-12-20_Training", "gopro.mp4"),
                ("Bob", "2025-12-20_Training", "rear.mov"),
            }
            self.assertEqual(destinations, expected)


if __name__ == "__main__":  # pragma: no cover
    unittest.main()
