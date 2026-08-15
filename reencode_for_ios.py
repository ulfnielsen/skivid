#!/usr/bin/env python3
"""Re-encode clips iPads cannot decode, in place, keeping their Drive file ids.

Every clip resized before ``resize_video.py`` pinned its output (commit
982b761, 2026-08-01) came out as H.264 **High 4:4:4 Predictive, 10-bit**.
VideoToolbox on iPhone and iPad has no decoder for that, so those clips play
their audio and show a blank frame on an iPad while looking perfect on a Mac.
This converts them to the 8-bit 4:2:0 the rest of the library already uses.

Two things it is careful about, both of which matter more than speed:

**File ids survive.** SkiVideoViewer keys a clip's annotations, sync anchors
and cached analysis by Drive file id. Uploading a converted copy would create a
new id and orphan all of it, so this updates each file's *content* in place and
never creates or deletes anything.

**Nothing is replaced until its replacement is checked.** A re-encode that
truncates or drops audio is worse than the unplayable original, because the
original is at least still convertible. Each output is probed for the right
pixel format and a matching duration before it goes anywhere.

Dry run unless you pass ``--apply``.

    # See what would change, touching nothing
    ./reencode_for_ios.py --drive-folder 0AGx...

    # Convert a local tree instead
    ./reencode_for_ios.py --local ~/Ski/organized --apply

    # Do it for real, on Drive
    ./reencode_for_ios.py --drive-folder 0AGx... --apply
"""

from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Iterable, Iterator, NamedTuple, Optional

VIDEO_SUFFIXES = {".mp4", ".mov", ".m4v"}

# H.264 profiles iOS has no decoder for, keyed by the name ffprobe reports.
# A list of what is unsupported rather than a comparison against High, because
# profile numbers are not ordered by capability.
UNSUPPORTED_PROFILES = {
    "High 10": "10-bit",
    "High 4:2:2": "4:2:2",
    "High 4:4:4 Predictive": "10-bit 4:4:4",
}

# What resize_video.py pins its output to, and what this converts to.
TARGET_PIX_FMT = "yuv420p"

# Durations are compared with a tolerance because a re-encode may land on a
# slightly different final frame boundary. Anything beyond this is truncation.
DURATION_TOLERANCE_SECONDS = 0.5


class Probe(NamedTuple):
    codec: str
    profile: str
    pix_fmt: str
    duration: float
    has_audio: bool

    @property
    def unsupported_reason(self) -> Optional[str]:
        """Why an iPad cannot play this, or None if it can."""
        if self.codec != "h264":
            # HEVC Main10 decodes fine on iOS; a bit-depth rule written across
            # codecs would flag clips that play.
            return None
        return UNSUPPORTED_PROFILES.get(self.profile)


def probe(path: Path) -> Optional[Probe]:
    """None when ffprobe cannot read the file or it carries no video."""
    result = subprocess.run(
        [
            "ffprobe", "-v", "error", "-print_format", "json",
            "-show_streams", "-show_format", str(path),
        ],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        return None
    try:
        parsed = json.loads(result.stdout)
    except json.JSONDecodeError:
        return None

    streams = parsed.get("streams", [])
    video = next((s for s in streams if s.get("codec_type") == "video"), None)
    if video is None:
        return None

    # Duration lives on the format for some containers and on the stream for
    # others; a missing one must not silently become 0.0, which would make the
    # verification below pass for a truncated file.
    raw_duration = video.get("duration") or parsed.get("format", {}).get("duration")
    try:
        duration = float(raw_duration)
    except (TypeError, ValueError):
        duration = float("nan")

    return Probe(
        codec=video.get("codec_name", ""),
        profile=video.get("profile", ""),
        pix_fmt=video.get("pix_fmt", ""),
        duration=duration,
        has_audio=any(s.get("codec_type") == "audio" for s in streams),
    )


def reencode(source: Path, destination: Path) -> None:
    """Convert to 8-bit 4:2:0, changing nothing else that can be preserved.

    Audio is stream-copied rather than re-encoded: it decodes fine already, and
    a second lossy pass would cost quality for no reason. ``-movflags
    +faststart`` puts the moov atom first so the app can begin playing a clip
    while the rest is still arriving.
    """
    command = [
        "ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
        "-i", str(source),
        "-c:v", "libx264",
        "-profile:v", "high",
        "-pix_fmt", TARGET_PIX_FMT,
        # Visually lossless for camera footage, and this is a one-off pass over
        # clips that were already encoded once — worth spending bits to avoid a
        # visible second generation.
        "-crf", "18",
        "-preset", "medium",
        "-c:a", "copy",
        "-movflags", "+faststart",
        str(destination),
    ]
    subprocess.run(command, check=True, capture_output=True, text=True)


def verify(original: Probe, converted_path: Path) -> Optional[str]:
    """None when the conversion is good; otherwise why it must not be used."""
    result = probe(converted_path)
    if result is None:
        return "ffprobe could not read the converted file"
    if result.pix_fmt != TARGET_PIX_FMT:
        return f"converted file is {result.pix_fmt}, expected {TARGET_PIX_FMT}"
    if result.unsupported_reason is not None:
        return f"converted file is still unplayable ({result.unsupported_reason})"
    if original.has_audio and not result.has_audio:
        return "conversion lost the audio track"
    if original.duration == original.duration:  # not NaN
        drift = abs(result.duration - original.duration)
        if not (drift <= DURATION_TOLERANCE_SECONDS):  # also catches NaN
            return (
                f"converted duration {result.duration:.2f}s differs from "
                f"{original.duration:.2f}s by more than {DURATION_TOLERANCE_SECONDS}s"
            )
    return None


# --- Local mode ------------------------------------------------------------


def local_videos(root: Path) -> Iterator[Path]:
    for path in sorted(root.rglob("*")):
        if path.is_file() and path.suffix.lower() in VIDEO_SUFFIXES:
            yield path


def convert_local(path: Path, *, apply: bool) -> str:
    original = probe(path)
    if original is None:
        return f"SKIP  {path} (unreadable)"
    reason = original.unsupported_reason
    if reason is None:
        return f"OK    {path} ({original.profile}, {original.pix_fmt})"
    if not apply:
        return f"WOULD {path} ({reason} -> {TARGET_PIX_FMT})"

    with tempfile.TemporaryDirectory() as directory:
        converted = Path(directory) / path.name
        try:
            reencode(path, converted)
        except subprocess.CalledProcessError as error:
            return f"FAIL  {path}: ffmpeg failed: {error.stderr.strip()[:200]}"
        problem = verify(original, converted)
        if problem is not None:
            return f"FAIL  {path}: {problem} — original left alone"
        # Replaced only after the check above passed. shutil.move across the
        # temp dir's filesystem is a copy-then-unlink, so the original stays
        # readable until the new bytes are fully written.
        shutil.move(str(converted), str(path))
    return f"FIXED {path} ({reason} -> {TARGET_PIX_FMT})"


# --- Drive mode ------------------------------------------------------------


def drive_videos(service, folder_id: str) -> Iterator[dict]:
    """Every video under a folder or shared drive, recursively."""
    pending = [folder_id]
    seen: set[str] = set()
    while pending:
        parent = pending.pop()
        page_token = None
        while True:
            response = service.files().list(
                q=f"'{parent}' in parents and trashed = false",
                fields="nextPageToken, files(id, name, mimeType, modifiedTime)",
                pageSize=1000,
                supportsAllDrives=True,
                includeItemsFromAllDrives=True,
                pageToken=page_token,
            ).execute()
            for item in response.get("files", []):
                if item["id"] in seen:
                    continue
                seen.add(item["id"])
                if item["mimeType"] == "application/vnd.google-apps.folder":
                    pending.append(item["id"])
                elif item["mimeType"].startswith("video/"):
                    yield item
            page_token = response.get("nextPageToken")
            if not page_token:
                break


def convert_drive_file(service, item: dict, *, apply: bool) -> str:
    from googleapiclient.http import MediaFileUpload, MediaIoBaseDownload

    name = item["name"]
    with tempfile.TemporaryDirectory() as directory:
        downloaded = Path(directory) / name
        request = service.files().get_media(fileId=item["id"], supportsAllDrives=True)
        with open(downloaded, "wb") as handle:
            downloader = MediaIoBaseDownload(handle, request)
            done = False
            while not done:
                _, done = downloader.next_chunk()

        original = probe(downloaded)
        if original is None:
            return f"SKIP  {name} (unreadable)"
        reason = original.unsupported_reason
        if reason is None:
            return f"OK    {name} ({original.profile}, {original.pix_fmt})"
        if not apply:
            return f"WOULD {name} ({reason} -> {TARGET_PIX_FMT})"

        converted = Path(directory) / f"converted-{name}"
        try:
            reencode(downloaded, converted)
        except subprocess.CalledProcessError as error:
            return f"FAIL  {name}: ffmpeg failed: {error.stderr.strip()[:200]}"
        problem = verify(original, converted)
        if problem is not None:
            return f"FAIL  {name}: {problem} — Drive file left alone"

        # update(), not create(): the file id is what SkiVideoViewer keys a
        # clip's annotations and cached analysis by, so a new file would orphan
        # every note a coach has made on this clip.
        service.files().update(
            fileId=item["id"],
            media_body=MediaFileUpload(str(converted), resumable=True),
            supportsAllDrives=True,
        ).execute()
    return f"FIXED {name} ({reason} -> {TARGET_PIX_FMT})"


def build_drive_service(client_secrets: Path, token: Path, scope: str):
    from google.auth.transport.requests import Request
    from google.oauth2.credentials import Credentials
    from google_auth_oauthlib.flow import InstalledAppFlow
    from googleapiclient.discovery import build

    scopes = [f"https://www.googleapis.com/auth/{scope}"]
    creds = None
    if token.is_file():
        creds = Credentials.from_authorized_user_file(str(token), scopes)
    if not creds or not creds.valid:
        if creds and creds.expired and creds.refresh_token:
            creds.refresh(Request())
        else:
            flow = InstalledAppFlow.from_client_secrets_file(str(client_secrets), scopes)
            creds = flow.run_local_server(port=0)
        token.write_text(creds.to_json())
    return build("drive", "v3", credentials=creds)


def parse_args(argv: Optional[Iterable[str]] = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--local", type=Path, help="Directory tree to convert in place")
    source.add_argument("--drive-folder", help="Drive folder or shared drive id to convert in place")
    parser.add_argument(
        "--apply",
        action="store_true",
        help="Actually convert. Without it nothing is written and every clip is only reported.",
    )
    parser.add_argument("--client-secrets", type=Path, default=Path("client_secret.json"))
    parser.add_argument("--token", type=Path, default=Path("token.json"))
    parser.add_argument(
        "--scope",
        default="drive.file",
        help="drive.file reaches files this client uploaded, which is how the library got there. "
             "Use 'drive' if the clips were put in Drive some other way.",
    )
    return parser.parse_args(list(argv) if argv is not None else None)


def main(argv: Optional[Iterable[str]] = None) -> int:
    args = parse_args(argv)
    if shutil.which("ffmpeg") is None or shutil.which("ffprobe") is None:
        print("ffmpeg and ffprobe must be on PATH", file=sys.stderr)
        return 2

    if not args.apply:
        print("Dry run — nothing will be written. Pass --apply to convert.\n")

    counts = {"FIXED": 0, "WOULD": 0, "OK": 0, "FAIL": 0, "SKIP": 0}
    if args.local:
        for path in local_videos(args.local):
            line = convert_local(path, apply=args.apply)
            print(line, flush=True)
            counts[line.split()[0]] += 1
    else:
        service = build_drive_service(args.client_secrets, args.token, args.scope)
        for item in drive_videos(service, args.drive_folder):
            line = convert_drive_file(service, item, apply=args.apply)
            print(line, flush=True)
            counts[line.split()[0]] += 1

    print(
        f"\n{counts['OK']} already fine, "
        f"{counts['WOULD'] + counts['FIXED']} need converting, "
        f"{counts['FAIL']} failed, {counts['SKIP']} skipped."
    )
    # A failure is worth a non-zero exit: over hundreds of clips the summary
    # scrolls away, and this is what a wrapping script can act on.
    return 1 if counts["FAIL"] else 0


if __name__ == "__main__":
    raise SystemExit(main())
