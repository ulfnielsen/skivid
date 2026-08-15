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

# Codecs AVFoundation decodes on iOS without help. HEVC is here because that is
# what an iPhone or a modern camera writes, and a club's Drive fills up with it
# as soon as anyone uploads their own footage — flagging those would mean
# re-encoding clips that already play perfectly.
#
# Everything absent from this list is treated as unplayable, which is the safe
# direction: VP9 and AV1 in particular arrive from browser and editor exports
# and AVPlayer cannot open either.
NATIVELY_PLAYABLE_CODECS = {"hevc", "h264", "mpeg4", "mjpeg"}

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
    width: int = 0
    height: int = 0

    @property
    def has_odd_dimension(self) -> bool:
        """4:2:0 stores chroma at half resolution in both axes, so libx264
        refuses an odd width or height outright: "width not divisible by 2".

        Real footage hits this — a phone clip through resize_video.py came out
        1215x2160 — and the original is 4:4:4, where the constraint does not
        apply, which is exactly why it survived the first encode and fails this
        one.
        """
        return self.width % 2 == 1 or self.height % 2 == 1

    @property
    def unsupported_reason(self) -> Optional[str]:
        """Why an iPad cannot play this, or None if it can.

        Two populations end up in a club's Drive and they fail differently.
        Clips this pipeline produced are H.264, and the ones from before
        2026-08-01 are in profiles iOS has no decoder for. Clips a coach
        uploaded from a phone or laptop are whatever their device exports —
        usually HEVC, which iOS plays natively, but a browser or editor export
        can be VP9 or AV1, which AVFoundation does not decode at all.
        """
        if self.codec == "h264":
            return UNSUPPORTED_PROFILES.get(self.profile)
        if self.codec in NATIVELY_PLAYABLE_CODECS:
            return None
        # Anything else: AVPlayer has no decoder, so it is as unplayable as the
        # 4:4:4 clips even though it got there a completely different way.
        return self.codec or "an unrecognised codec"


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
        width=int(video.get("width") or 0),
        height=int(video.get("height") or 0),
    )


def reencode(source: Path, destination: Path, original: Probe, crf: int) -> None:
    """Convert to 8-bit 4:2:0, changing nothing else that can be preserved.

    Audio is stream-copied rather than re-encoded: it decodes fine already, and
    a second lossy pass would cost quality for no reason. ``-movflags
    +faststart`` puts the moov atom first so the app can begin playing a clip
    while the rest is still arriving.
    """
    command = [
        "ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
        "-i", str(source),
    ]
    if original.has_odd_dimension:
        # Rounds down to the nearest even size, losing at most one row or
        # column. Applied only when needed: an unconditional scale filter would
        # put every clip in the library through the scaler for nothing.
        command += ["-vf", "scale=trunc(iw/2)*2:trunc(ih/2)*2"]
    command += [
        "-c:v", "libx264",
        "-profile:v", "high",
        "-pix_fmt", TARGET_PIX_FMT,
        "-crf", str(crf),
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
    if original.has_odd_dimension:
        # At most one row or column was trimmed to reach an even size.
        if abs(result.width - original.width) > 1 or abs(result.height - original.height) > 1:
            return (
                f"converted size {result.width}x{result.height} is not the expected "
                f"even-rounded {original.width}x{original.height}"
            )
    elif (result.width, result.height) != (original.width, original.height):
        return f"converted size {result.width}x{result.height} != {original.width}x{original.height}"
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


def convert_local(path: Path, *, apply: bool, crf: int) -> str:
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
            reencode(path, converted, original, crf)
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
    # Each entry carries the folder names walked to reach it, so a clip can be
    # reported by where it lives rather than by a camera filename that recurs
    # across every athlete in the library.
    pending: list[tuple[str, list[str]]] = [(folder_id, [])]
    seen: set[str] = set()
    while pending:
        parent, ancestors = pending.pop()
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
                    pending.append((item["id"], [*ancestors, item["name"]]))
                elif item["mimeType"].startswith("video/"):
                    yield {**item, "display": "/".join([*ancestors, item["name"]])}
            page_token = response.get("nextPageToken")
            if not page_token:
                break


def default_index_path() -> Optional[Path]:
    """The app's own index of the library, if exactly one is present.

    `~/Library/Application Support/SkiVideoViewer/RemoteLibrary/<key>.skiindex.json`
    is written per Drive root, so more than one means more than one library and
    the caller has to say which.
    """
    directory = (
        Path.home() / "Library" / "Application Support"
        / "SkiVideoViewer" / "RemoteLibrary"
    )
    matches = sorted(directory.glob("*.skiindex.json")) if directory.is_dir() else []
    return matches[0] if len(matches) == 1 else None


def index_videos(index_path: Path) -> list[dict]:
    """Every clip SkiVideoViewer knows about, from its own index.

    Preferred over walking folders, because the two can disagree and only this
    one matters: it is precisely the set the app will try to play. Folder
    traversal additionally depends on what the OAuth scope can *see* —
    `drive.file` reaches only files its client uploaded — so a library that
    reached Drive by more than one route enumerates short, silently, and
    reports success over a partial run.
    """
    data = json.loads(index_path.read_text())
    files = data.get("files", [])
    if not files:
        raise SystemExit(f"{index_path} lists no files — is it the right index?")
    clips = []
    for entry in files:
        name = entry.get("name", entry["id"])
        if Path(name).suffix.lower() not in VIDEO_SUFFIXES:
            continue
        # `path` is the folder components the app derives athlete and event
        # from — ["Harry Korrodi", "2026-01-14_Brunni"] — so joining them with
        # the file name gives the location a coach would recognise in Drive.
        # Names alone are useless here: the library is full of C0027.MP4 and
        # the same camera filename recurs across athletes and events.
        components = entry.get("path") or []
        clips.append({
            "id": entry["id"],
            "name": name,
            "display": "/".join([*components, name]),
        })
    return clips


def convert_drive_file(service, item: dict, *, apply: bool, crf: int) -> str:
    from googleapiclient.http import MediaFileUpload, MediaIoBaseDownload

    name = item["name"]
    # Where the clip lives, for every line this function prints. The bare file
    # name is ambiguous across a library where each athlete's camera writes
    # C0001.MP4; the temp file below still uses `name`, because that is what
    # ffmpeg needs a valid filename for.
    label = item.get("display") or name
    with tempfile.TemporaryDirectory() as directory:
        downloaded = Path(directory) / name
        request = service.files().get_media(fileId=item["id"], supportsAllDrives=True)
        try:
            with open(downloaded, "wb") as handle:
                downloader = MediaIoBaseDownload(handle, request)
                done = False
                while not done:
                    _, done = downloader.next_chunk()
        except Exception as error:
            # One unreachable clip must not end a run over hundreds. A 403 here
            # usually means --scope drive.file cannot reach a file this client
            # did not upload; the summary counts it so a partial run cannot
            # pass for a complete one.
            status = getattr(getattr(error, "resp", None), "status", None)
            detail = f"HTTP {status}" if status else type(error).__name__
            return f"FAIL  {label}: could not download ({detail})"

        original = probe(downloaded)
        if original is None:
            return f"SKIP  {label} (unreadable)"
        reason = original.unsupported_reason
        if reason is None:
            return f"OK    {label} ({original.profile}, {original.pix_fmt})"
        if not apply:
            return f"WOULD {label} ({reason} -> {TARGET_PIX_FMT})"

        converted = Path(directory) / f"converted-{name}"
        try:
            reencode(downloaded, converted, original, crf)
        except subprocess.CalledProcessError as error:
            return f"FAIL  {label}: ffmpeg failed: {error.stderr.strip()[:200]}"
        problem = verify(original, converted)
        if problem is not None:
            return f"FAIL  {label}: {problem} — Drive file left alone"

        # update(), not create(): the file id is what SkiVideoViewer keys a
        # clip's annotations and cached analysis by, so a new file would orphan
        # every note a coach has made on this clip.
        service.files().update(
            fileId=item["id"],
            media_body=MediaFileUpload(str(converted), resumable=True),
            supportsAllDrives=True,
        ).execute()
    return f"FIXED {label} ({reason} -> {TARGET_PIX_FMT})"


def _import_google_libraries():
    """The Drive libraries, or an explanation of where they actually live.

    They are not installed in the system Python — they are in this directory's
    `.venv`, the same one `upload_to_drive.py` needs. Running this script with a
    bare `python3` therefore dies with `ModuleNotFoundError: No module named
    'google'`, which says nothing about the venv sitting right beside it.
    """
    try:
        from google.auth.transport.requests import Request
        from google.oauth2.credentials import Credentials
        from google_auth_oauthlib.flow import InstalledAppFlow
        from googleapiclient.discovery import build
    except ImportError as error:
        venv_python = Path(__file__).resolve().parent / ".venv" / "bin" / "python"
        hint = (
            f"Run it with that instead:\n\n    {venv_python} {Path(__file__).name} ...\n"
            if venv_python.is_file()
            else "Create one, then:\n\n    pip install "
                 "google-api-python-client google-auth-oauthlib\n"
        )
        raise SystemExit(
            f"The Google Drive libraries are not available to this Python "
            f"({sys.executable}).\n\n{hint}\n"
            f"(Local mode needs none of this — only --drive-folder does.)\n\n"
            f"Original error: {error}"
        ) from error
    return Request, Credentials, InstalledAppFlow, build


def default_client_secrets() -> Path:
    """The first `client_secret*.json` beside this script.

    Google names the file after the client id, so the literal
    `client_secret.json` this used to default to matches nothing anyone
    actually downloads. Sorted for determinism when a directory holds more than
    one — the same rule `GoogleClientSecretsLoader` follows in the app.
    """
    here = Path(__file__).resolve().parent
    matches = sorted(here.glob("client_secret*.json"))
    return matches[0] if matches else here / "client_secret.json"


def build_drive_service(client_secrets: Path, token: Path, scope: str):
    Request, Credentials, InstalledAppFlow, build = _import_google_libraries()

    if not client_secrets.is_file() and not token.is_file():
        raise SystemExit(
            f"No credentials: expected {client_secrets} or an existing {token}.\n"
            f"Point at them with --client-secrets / --token — the same files "
            f"upload_to_drive.py uses."
        )

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
    source.add_argument(
        "--from-index",
        nargs="?",
        const="auto",
        metavar="PATH",
        help="Take the clip list from SkiVideoViewer's own index instead of walking "
             "folders — the authoritative set, since it is exactly what the app plays. "
             "Defaults to the one under ~/Library/Application Support/SkiVideoViewer.",
    )
    parser.add_argument(
        "--apply",
        action="store_true",
        help="Actually convert. Without it nothing is written and every clip is only reported.",
    )
    parser.add_argument(
        "--crf",
        type=int,
        default=21,
        help="x264 quality, lower is better. Default 21, chosen by measuring a real "
             "1080p50 clip from the library: it lands within 1%% of the source file "
             "size at 46.1dB PSNR / 0.986 SSIM. CRF 18 measured 47.5dB — "
             "indistinguishable — for 47%% more storage.",
    )
    parser.add_argument(
        "--sample",
        type=int,
        metavar="N",
        help="Only look at the first N clips. A clip's codec cannot be known without "
             "its bytes, so a full Drive dry run downloads the whole library — tens of "
             "gigabytes — to answer a question a handful of clips usually settles.",
    )
    parser.add_argument(
        "--client-secrets",
        type=Path,
        default=None,
        help="Defaults to the first client_secret*.json beside this script.",
    )
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
        # Flushed, or stdout buffering lets a stderr message overtake it and the
        # banner lands underneath the error it was meant to precede.
        print("Dry run — nothing will be written. Pass --apply to convert.\n", flush=True)

    counts = {"FIXED": 0, "WOULD": 0, "OK": 0, "FAIL": 0, "SKIP": 0}
    if args.local:
        for path in local_videos(args.local):
            line = convert_local(path, apply=args.apply, crf=args.crf)
            print(line, flush=True)
            counts[line.split()[0]] += 1
    elif args.from_index:
        index_path = (
            default_index_path() if args.from_index == "auto" else Path(args.from_index)
        )
        if index_path is None or not index_path.is_file():
            raise SystemExit(
                "No SkiVideoViewer index found. Open the club library in the app "
                "once so it writes one, or pass the path: --from-index <file>.skiindex.json"
            )
        clips = index_videos(index_path)
        total = len(clips)
        if args.sample:
            clips = clips[: args.sample]
        # Says what was left out. A cap that reports only what it looked at
        # reads as "the library is fine" when it means "these few were".
        print(
            f"{total} clips in {index_path.name}"
            + (f" — looking at the first {len(clips)}\n" if args.sample else "\n"),
            flush=True,
        )
        service = build_drive_service(
            args.client_secrets or default_client_secrets(), args.token, args.scope
        )
        for item in clips:
            line = convert_drive_file(service, item, apply=args.apply, crf=args.crf)
            print(line, flush=True)
            counts[line.split()[0]] += 1
    else:
        service = build_drive_service(
            args.client_secrets or default_client_secrets(), args.token, args.scope
        )
        try:
            for item in drive_videos(service, args.drive_folder):
                line = convert_drive_file(service, item, apply=args.apply, crf=args.crf)
                print(line, flush=True)
                counts[line.split()[0]] += 1
        except Exception as error:  # googleapiclient.errors.HttpError and friends
            # A traceback here is unreadable and blames the wrong thing: the
            # overwhelmingly common causes are a mistyped id and a scope that
            # cannot see the folder, neither of which is a bug in this script.
            status = getattr(getattr(error, "resp", None), "status", None)
            if status == 404:
                print(
                    f"\nDrive has no folder '{args.drive_folder}' visible to this account.\n"
                    f"Check the id, and note that --scope is currently {args.scope}: "
                    f"drive.file only reaches files this OAuth client uploaded. "
                    f"If the clips got into Drive another way, pass --scope drive.",
                    file=sys.stderr,
                )
                return 2
            if status == 403:
                print(
                    f"\nDrive refused access to '{args.drive_folder}' (403). The signed-in "
                    f"account is probably not a member of that shared drive.",
                    file=sys.stderr,
                )
                return 2
            raise

    print(
        f"\n{counts['OK']} already fine, "
        f"{counts['WOULD'] + counts['FIXED']} need converting, "
        f"{counts['FAIL']} failed, {counts['SKIP']} skipped.",
        flush=True,
    )
    # The failure mode this guards against is a run that looks complete and is
    # not: with --scope drive.file every clip a coach uploaded themselves is
    # unreachable, and without this the only sign is a FAIL line that scrolled
    # past hundreds of clips ago.
    if counts["FAIL"] and args.scope == "drive.file":
        print(
            f"\n{counts['FAIL']} clips could not be handled. If they are ones people "
            f"uploaded to Drive themselves rather than through upload_to_drive.py, "
            f"that is expected: --scope drive.file only reaches files this OAuth "
            f"client created. Re-run with --scope drive to cover them.",
            file=sys.stderr,
        )
    # A failure is worth a non-zero exit: over hundreds of clips the summary
    # scrolls away, and this is what a wrapping script can act on.
    return 1 if counts["FAIL"] else 0


if __name__ == "__main__":
    raise SystemExit(main())
