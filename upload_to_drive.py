"""Upload local video folders to Google Drive using the Drive API."""

from __future__ import annotations

import argparse
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Tuple

from googleapiclient.discovery import build
from googleapiclient.errors import HttpError
from googleapiclient.http import MediaFileUpload
from google.auth.transport.requests import Request
from google.oauth2 import service_account
from google.oauth2.credentials import Credentials as OAuthCredentials
from google_auth_oauthlib.flow import InstalledAppFlow

VIDEO_EXTENSIONS = (".mp4", ".mov", ".m4v", ".avi", ".mkv", ".webm")
DRIVE_FOLDER_MIME = "application/vnd.google-apps.folder"
SCOPES = ["https://www.googleapis.com/auth/drive.file"]
DRIVE_LIST_KWARGS = {"supportsAllDrives": True, "includeItemsFromAllDrives": True}
DRIVE_WRITE_KWARGS = {"supportsAllDrives": True}


@dataclass(frozen=True)
class UploadPlanEntry:
    local_path: Path
    athlete: str
    event: str


def _is_video(path: Path) -> bool:
    return path.suffix.lower() in VIDEO_EXTENSIONS


def _format_size(num_bytes: int) -> str:
    units = ["B", "KB", "MB", "GB", "TB"]
    size = float(num_bytes)
    for unit in units:
        if size < 1024 or unit == units[-1]:
            return f"{size:.1f} {unit}"
        size /= 1024


def _derive_event_athlete(source_dir: Path, file_path: Path) -> Tuple[str, str]:
    relative = file_path.relative_to(source_dir)
    parts = relative.parts
    if len(parts) >= 3:
        event, athlete = parts[0], parts[1]
    elif len(parts) == 2:
        event, athlete = source_dir.name, parts[0]
    elif len(parts) == 1:
        parent = source_dir.parent
        if parent == source_dir:
            raise ValueError("Cannot infer event/athlete from top-level directory")
        event, athlete = parent.name, source_dir.name
    else:
        raise ValueError(f"Unexpected relative path structure for {file_path}")
    return event, athlete


def plan_drive_uploads(source_dir: Path, include_non_video: bool = False) -> List[UploadPlanEntry]:
    """Return upload plan entries where Drive folders are grouped athlete → event."""

    if not source_dir.is_dir():
        raise FileNotFoundError(f"Source directory not found: {source_dir}")

    plan: List[UploadPlanEntry] = []
    for file_path in sorted(p for p in source_dir.rglob("*") if p.is_file()):
        if not include_non_video and not _is_video(file_path):
            continue
        event, athlete = _derive_event_athlete(source_dir, file_path)
        plan.append(
            UploadPlanEntry(
                local_path=file_path,
                athlete=athlete,
                event=event,
            )
        )
    return plan


def _build_service_from_service_account(credentials_path: Path):
    creds = service_account.Credentials.from_service_account_file(
        str(credentials_path), scopes=SCOPES
    )
    return build("drive", "v3", credentials=creds)


def _build_service_from_oauth(client_secrets: Path, token_store: Path):
    creds: Optional[OAuthCredentials] = None
    if token_store.exists():
        creds = OAuthCredentials.from_authorized_user_file(str(token_store), SCOPES)
    if not creds or not creds.valid:
        if creds and creds.expired and creds.refresh_token:
            creds.refresh(Request())
        else:
            flow = InstalledAppFlow.from_client_secrets_file(str(client_secrets), SCOPES)
            creds = flow.run_local_server(port=0)
        token_store.parent.mkdir(parents=True, exist_ok=True)
        token_store.write_text(creds.to_json())
    return build("drive", "v3", credentials=creds)


def _escape_name(name: str) -> str:
    return name.replace("'", "\\'")


def _find_existing_folder(service, name: str, parent_id: Optional[str]) -> Optional[str]:
    query = [f"mimeType='{DRIVE_FOLDER_MIME}'", "trashed = false", f"name = '{_escape_name(name)}'"]
    if parent_id:
        query.append(f"'{parent_id}' in parents")
    query_str = " and ".join(query)
    response = (
        service.files()
        .list(
            q=query_str,
            spaces="drive",
            fields="files(id, name)",
            pageSize=1,
            **DRIVE_LIST_KWARGS,
        )
        .execute()
    )
    files = response.get("files", [])
    if files:
        return files[0]["id"]
    return None


def _find_existing_file(service, name: str, parent_id: str) -> Optional[Dict[str, str]]:
    query = [
        "trashed = false",
        f"mimeType != '{DRIVE_FOLDER_MIME}'",
        f"name = '{_escape_name(name)}'",
        f"'{parent_id}' in parents",
    ]
    response = (
        service.files()
        .list(
            q=" and ".join(query),
            spaces="drive",
            fields="files(id, size)",
            pageSize=1,
            **DRIVE_LIST_KWARGS,
        )
        .execute()
    )
    files = response.get("files", [])
    if files:
        return files[0]
    return None


def _ensure_remote_folder(service, name: str, parent_id: Optional[str]) -> str:
    existing_id = _find_existing_folder(service, name, parent_id)
    if existing_id:
        return existing_id
    metadata = {"name": name, "mimeType": DRIVE_FOLDER_MIME}
    if parent_id:
        metadata["parents"] = [parent_id]
    folder = (
        service.files()
        .create(body=metadata, fields="id", **DRIVE_WRITE_KWARGS)
        .execute()
    )
    return folder["id"]


def _upload_file(
    service,
    local_path: Path,
    parent_id: str,
    *,
    overwrite_id: Optional[str] = None,
    resumable: bool = True,
) -> str:
    metadata = {"name": local_path.name, "parents": [parent_id]}
    media = MediaFileUpload(
        str(local_path),
        resumable=resumable,
        chunksize=10 * 1024 * 1024,
    )
    if overwrite_id:
        request = service.files().update(
            fileId=overwrite_id, media_body=media, fields="id", **DRIVE_WRITE_KWARGS
        )
    else:
        request = service.files().create(
            body=metadata, media_body=media, fields="id", **DRIVE_WRITE_KWARGS
        )
    response = None
    file_size = local_path.stat().st_size
    last_percent = -1
    while response is None:
        status, response = request.next_chunk()
        if status:
            percent = int(status.progress() * 100)
            if percent != last_percent:
                sys.stdout.write(
                    f"\rUploading {local_path.name}: {percent}% ({_format_size(file_size)})"
                )
                sys.stdout.flush()
                last_percent = percent
    sys.stdout.write(f"\rUploading {local_path.name}: 100% ({_format_size(file_size)})\n")
    sys.stdout.flush()
    return response["id"]


def _upload_file_if_needed(service, local_path: Path, parent_id: str) -> bool:
    file_size = local_path.stat().st_size
    existing = _find_existing_file(service, local_path.name, parent_id)
    existing_size = int(existing.get("size", "0")) if existing and existing.get("size") else 0
    if existing and existing_size == file_size:
        sys.stdout.write(
            f"Skipping {local_path.name}: already uploaded ({_format_size(file_size)})\n"
        )
        sys.stdout.flush()
        return False

    overwrite_id = existing["id"] if existing else None
    _upload_file(service, local_path, parent_id, overwrite_id=overwrite_id)
    return True


def upload_tree(
    source_dir: Path,
    service,
    *,
    drive_parent: str = "root",
    drive_root_name: Optional[str] = None,
    include_non_video: bool = False,
) -> List[str]:
    source_dir = source_dir.expanduser().resolve()
    if not source_dir.is_dir():
        raise FileNotFoundError(f"Source directory not found: {source_dir}")

    plan = plan_drive_uploads(source_dir, include_non_video=include_non_video)
    if not plan:
        return []

    parent_id = drive_parent or "root"
    if drive_root_name:
        root_drive_id = _ensure_remote_folder(service, drive_root_name, parent_id)
    else:
        root_drive_id = parent_id

    folder_cache: Dict[Tuple[str, str], str] = {}

    def _cached_folder(name: str, parent: str) -> str:
        key = (parent, name)
        if key not in folder_cache:
            folder_cache[key] = _ensure_remote_folder(service, name, parent)
        return folder_cache[key]

    uploaded_files: List[str] = []
    for entry in plan:
        athlete_drive_id = _cached_folder(entry.athlete, root_drive_id)
        event_drive_id = _cached_folder(entry.event, athlete_drive_id)
        target_desc = f"{entry.athlete}/{entry.event}/{entry.local_path.name}"
        sys.stdout.write(f"Planning upload: {entry.local_path} -> {target_desc}\n")
        sys.stdout.flush()
        try:
            did_upload = _upload_file_if_needed(service, entry.local_path, event_drive_id)
        except HttpError as exc:
            raise RuntimeError(f"Failed to upload {entry.local_path}: {exc}") from exc
        if did_upload:
            uploaded_files.append(str(entry.local_path))

    return uploaded_files


def _build_drive_service(args: argparse.Namespace):
    if args.auth_method == "service-account":
        if not args.credentials:
            raise ValueError("--credentials is required when auth method is service-account")
        credentials_path = Path(args.credentials)
        if not credentials_path.is_file():
            raise FileNotFoundError(f"Credentials file not found: {credentials_path}")
        return _build_service_from_service_account(credentials_path)

    if not args.client_secrets:
        raise ValueError("--client-secrets is required when auth method is oauth")
    client_secrets = Path(args.client_secrets)
    if not client_secrets.is_file():
        raise FileNotFoundError(f"Client secrets file not found: {client_secrets}")
    token_path = Path(args.token or "token.json")
    return _build_service_from_oauth(client_secrets, token_path)


def parse_args(argv: Optional[Iterable[str]] = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Upload video folders to Google Drive.")
    parser.add_argument("source", help="Local directory containing videos")
    parser.add_argument(
        "--auth-method",
        choices=["oauth", "service-account"],
        default="oauth",
        help="Authentication mode (default: oauth)",
    )
    parser.add_argument(
        "--credentials",
        help="Path to a service-account credentials JSON (service-account mode)",
    )
    parser.add_argument(
        "--client-secrets",
        help="Path to OAuth client secrets JSON (oauth mode)",
    )
    parser.add_argument(
        "--token",
        default="token.json",
        help="Where to read/write the OAuth user token (default: token.json)",
    )
    parser.add_argument(
        "--drive-parent",
        default="root",
        help="Drive folder ID to use as the parent (default: root of the account)",
    )
    parser.add_argument(
        "--drive-folder-name",
        help="Optional subfolder to create under --drive-parent before uploading",
    )
    parser.add_argument(
        "--include-non-video",
        action="store_true",
        help="Upload every file, not just recognized video extensions",
    )
    return parser.parse_args(list(argv) if argv is not None else None)


def main(argv: Optional[Iterable[str]] = None) -> int:
    args = parse_args(argv)
    source_dir = Path(args.source)

    try:
        service = _build_drive_service(args)
        uploaded = upload_tree(
            source_dir,
            service,
            drive_parent=args.drive_parent,
            drive_root_name=args.drive_folder_name,
            include_non_video=args.include_non_video,
        )
    except Exception as exc:
        print(str(exc), file=sys.stderr)
        return 1

    print(f"Uploaded {len(uploaded)} file(s) from {source_dir}")
    return 0


if __name__ == "__main__":
    import sys

    sys.exit(main())
