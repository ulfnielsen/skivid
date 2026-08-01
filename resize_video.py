"""Video resizing helper with CLI and importable API."""

from __future__ import annotations

import argparse
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, List, Optional

DEFAULT_WIDTH = 1920
DEFAULT_HEIGHT = 1080


@dataclass
class ResizeResult:
    """Represents the outcome of resizing a single file."""

    source: Path
    output: Path
    replaced: bool


class ResizeError(RuntimeError):
    """Raised when at least one file could not be processed."""


def _build_filter(max_width: int, max_height: int, brighten_percent: Optional[float], exposure_stops: Optional[float]) -> str:
    filters: List[str] = [
        f"scale=w={max_width}:h={max_height}:force_original_aspect_ratio=decrease",
    ]
    if brighten_percent is not None:
        filters.append(f"eq=brightness={brighten_percent / 100.0}")
    if exposure_stops is not None:
        filters.append(f"exposure={exposure_stops}")
    return ",".join(filters)


def _probe_duration(input_path: Path) -> Optional[float]:
    cmd = [
        "ffprobe",
        "-v",
        "error",
        "-show_entries",
        "format=duration",
        "-of",
        "default=noprint_wrappers=1:nokey=1",
        str(input_path),
    ]
    try:
        completed = subprocess.run(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            check=True,
        )
    except subprocess.CalledProcessError:
        return None
    try:
        return float(completed.stdout.strip())
    except ValueError:
        return None


def _run_ffmpeg(
    input_path: Path,
    output_path: Path,
    filter_chain: str,
    *,
    overwrite: bool,
    total_duration: Optional[float] = None,
) -> None:
    cmd = [
        "ffmpeg",
        "-hide_banner",
        "-loglevel",
        "error",
        "-progress",
        "pipe:2",
        "-nostats",
        "-y" if overwrite else "-n",
        "-i",
        str(input_path),
        "-vf",
        filter_chain,
        # Pin the output to 8-bit 4:2:0. Left to itself a modern x264 picks the
        # "best" format its build supports; with the `exposure` filter in the chain
        # ffmpeg negotiates all the way up to High 4:4:4 Predictive / 10-bit, which
        # VideoToolbox on iPhone and iPad cannot decode at all -- playback dies with
        # kVTVideoDecoderBadDataErr (-8969). Camera footage gains nothing visible
        # from the wider format either.
        "-pix_fmt",
        "yuv420p",
        str(output_path),
    ]
    proc = subprocess.Popen(
        cmd,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
        text=True,
    )
    last_percent = -1
    progress_label = f"    ffmpeg {input_path.name}"
    captured_errors: List[str] = []
    progress_started = False
    progress_completed = False

    def _render_progress(percent_display: str) -> None:
        nonlocal progress_started
        progress_started = True
        sys.stdout.write(f"\r{progress_label}: {percent_display}")
        sys.stdout.flush()

    if proc.stderr is None:
        _, stderr_data = proc.communicate()
        if stderr_data:
            captured_errors.append(stderr_data.strip())
    else:
        for raw_line in proc.stderr:
            line = raw_line.strip()
            if line.startswith("out_time_ms="):
                value = line.split("=", 1)[1]
                try:
                    seconds = int(value) / 1_000_000
                except ValueError:
                    continue
                if total_duration and total_duration > 0:
                    percent = min(int((seconds / total_duration) * 100), 100)
                    if percent != last_percent:
                        last_percent = percent
                        _render_progress(f"{percent}%")
                else:
                    _render_progress(f"{seconds:.1f}s")
            elif line.startswith("progress="):
                if line.endswith("end"):
                    progress_completed = True
                    _render_progress("100%")
                continue
            elif line:
                captured_errors.append(line)
        proc.wait()

    if progress_started:
        sys.stdout.write("\n")
        sys.stdout.flush()

    returncode = proc.returncode
    if returncode != 0:
        message = "; ".join(captured_errors) or "see ffmpeg output"
        raise RuntimeError(f"ffmpeg failed for '{input_path}': {message}")


def resize_video_file(
    video_file: Path | str,
    *,
    max_width: int = DEFAULT_WIDTH,
    max_height: int = DEFAULT_HEIGHT,
    brighten_percent: Optional[float] = None,
    exposure_stops: Optional[float] = None,
    replace: bool = False,
    overwrite_output: bool = False,
) -> ResizeResult:
    """Resize a single video file and return the outcome."""

    video_path = Path(video_file)
    if not video_path.is_file():
        raise FileNotFoundError(f"File not found: {video_path}")

    filter_chain = _build_filter(max_width, max_height, brighten_percent, exposure_stops)
    output_path = video_path.with_name(f"{video_path.stem}_resized{video_path.suffix}")
    allow_overwrite = overwrite_output or replace
    if output_path.exists() and not allow_overwrite:
        raise FileExistsError(
            f"Output already exists: {output_path}. Set overwrite_output=True or pass --overwrite-output to replace it."
        )

    duration_seconds = _probe_duration(video_path)

    try:
        _run_ffmpeg(
            video_path,
            output_path,
            filter_chain,
            overwrite=allow_overwrite,
            total_duration=duration_seconds,
        )
    except Exception:
        if output_path.exists():
            output_path.unlink(missing_ok=True)
        raise

    final_output = output_path
    replaced = False
    if replace:
        video_path.unlink()
        output_path.replace(video_path)
        final_output = video_path
        replaced = True

    return ResizeResult(source=video_path, output=final_output, replaced=replaced)


def resize_videos(
    video_files: Iterable[Path | str],
    *,
    max_width: int = DEFAULT_WIDTH,
    max_height: int = DEFAULT_HEIGHT,
    brighten_percent: Optional[float] = None,
    exposure_stops: Optional[float] = None,
    replace: bool = False,
    overwrite_output: bool = False,
) -> List[ResizeResult]:
    """Process multiple files, raising ResizeError if any fail."""

    files = list(video_files)
    total = len(files)
    results: List[ResizeResult] = []
    errors: List[str] = []
    if total == 0:
        return results

    for index, file in enumerate(files, start=1):
        sys.stdout.write(f"[{index}/{total}] Resizing {file}\n")
        sys.stdout.flush()
        try:
            result = resize_video_file(
                file,
                max_width=max_width,
                max_height=max_height,
                brighten_percent=brighten_percent,
                exposure_stops=exposure_stops,
                replace=replace,
                overwrite_output=overwrite_output,
            )
            results.append(result)
            target = result.source if result.replaced else result.output
            sys.stdout.write(f"[{index}/{total}] Finished -> {target}\n")
            sys.stdout.flush()
        except Exception as exc:  # pragma: no cover - CLI feedback
            errors.append(str(exc))
    if errors:
        joined = "\n".join(errors)
        raise ResizeError(joined)
    return results


def _parse_args(argv: Optional[List[str]] = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Resize one or more videos using ffmpeg.")
    parser.add_argument("files", nargs="+", help="Video files to process")
    parser.add_argument("-w", "--width", type=int, default=DEFAULT_WIDTH, help="Maximum output width")
    parser.add_argument("-ht", "--height", type=int, default=DEFAULT_HEIGHT, help="Maximum output height")
    parser.add_argument(
        "-b",
        "--brighten",
        type=float,
        default=None,
        help="Brighten by this percentage (e.g. 10 for +10%%)",
    )
    parser.add_argument(
        "-e",
        "--exposure",
        type=float,
        default=None,
        help="Adjust exposure by this many stops (e.g. 0.5 or -1)",
    )
    parser.add_argument(
        "-r",
        "--replace",
        action="store_true",
        help="Replace the original file instead of creating *_resized copies",
    )
    parser.add_argument(
        "--overwrite-output",
        action="store_true",
        help="Allow overwriting existing *_resized files (default: skip and raise)",
    )
    return parser.parse_args(argv)


def _validate_args(args: argparse.Namespace) -> None:
    if args.width <= 0:
        raise ValueError("Width must be a positive integer")
    if args.height <= 0:
        raise ValueError("Height must be a positive integer")
    if args.brighten is not None and args.brighten < 0:
        raise ValueError("Brighten percent must be zero or positive")


def main(argv: Optional[List[str]] = None) -> int:
    args = _parse_args(argv)
    try:
        _validate_args(args)
        results = resize_videos(
            args.files,
            max_width=args.width,
            max_height=args.height,
            brighten_percent=args.brighten,
            exposure_stops=args.exposure,
            replace=args.replace,
            overwrite_output=args.overwrite_output,
        )
    except ResizeError as exc:
        print(exc, file=sys.stderr)
        return 1
    except Exception as exc:  # pragma: no cover - CLI feedback
        print(exc, file=sys.stderr)
        return 1

    for result in results:
        if result.replaced:
            print(f"Video resized and replaced: {result.source}")
        else:
            print(f"Video resized: {result.output}")
    return 0


if __name__ == "__main__":  # pragma: no cover - CLI entry point
    sys.exit(main())
