import argparse
import atexit
import inspect
import json
import os
import re
import select
import shutil
import socket
import subprocess
import sys
import tempfile
import termios
import threading
import time
import tty
from datetime import datetime
from typing import List, Optional, Tuple

try:
    import readline
except ImportError:  # pragma: no cover
    readline = None

from resize_video import resize_video_file

# Parameters handled by the sorter itself; not exposed as --resize-* flags.
_RESIZE_SKIP_PARAMS = frozenset({"video_file", "replace", "overwrite_output"})


def _resize_param_type(param: inspect.Parameter):
    """Infer the argparse type for a resize_video_file parameter."""
    ann = param.annotation
    if ann is not inspect.Parameter.empty:
        # Unwrap Optional[X] / Union[X, None]
        if hasattr(ann, "__args__"):
            inner = [a for a in ann.__args__ if a is not type(None)]
            if inner:
                ann = inner[0]
        if ann in (int, float, str):
            return ann
    default = param.default
    if default not in (inspect.Parameter.empty, None):
        return type(default)
    return float  # sensible fallback for numeric resize params

# --- CONFIG ---
SOURCE = "~/Ski/Zurs20251213"  # Folder with raw videos
DEST = "~/Ski/Zurs20251213/organized"    # Where to move them
NAMES_FILE = "~/Ski/athletes.txt"  # Optional list of athlete names, one per line
BASE_DIR = os.path.dirname(os.path.abspath(__file__))


def resolve_path(path: str) -> str:
    """Expand user paths and resolve relatives against this script."""
    expanded = os.path.expanduser(path)
    if os.path.isabs(expanded):
        return expanded
    return os.path.abspath(os.path.join(BASE_DIR, expanded))


NAMES_PATH = resolve_path(NAMES_FILE) if NAMES_FILE else None


def load_name_list(path: Optional[str]) -> List[str]:
    if not path or not os.path.exists(path):
        return []
    with open(path, "r", encoding="utf-8") as handle:
        names = [line.strip() for line in handle]
    # Remove blanks while preserving order
    seen = set()
    ordered = []
    for name in names:
        if not name:
            continue
        key = name.lower()
        if key in seen:
            continue
        seen.add(key)
        ordered.append(name)
    return ordered


def _slugify_segment(text: str) -> str:
    # Keep unicode letters/numbers while normalizing separators to hyphens.
    cleaned = re.sub(r"[^\w]+", "-", text.strip(), flags=re.UNICODE)
    cleaned = cleaned.replace("_", "-")
    cleaned = re.sub(r"-+", "-", cleaned).strip("-")
    return cleaned or "event"


def detect_default_event_date(source_dir: str) -> str:
    fallback = datetime.now().strftime("%Y-%m-%d")
    if not source_dir or not os.path.isdir(source_dir):
        return fallback
    try:
        entries = os.listdir(source_dir)
    except OSError:
        return fallback
    mp4s = sorted(
        f for f in entries
        if f.lower().endswith(".mp4") and os.path.isfile(os.path.join(source_dir, f))
    )
    if not mp4s:
        return fallback
    first_path = os.path.join(source_dir, mp4s[0])
    try:
        timestamp = os.path.getmtime(first_path)
    except OSError:
        return fallback
    return datetime.fromtimestamp(timestamp).strftime("%Y-%m-%d")


def prompt_event_folder(default_date: str):
    """Ask the user for an event date and title to build the destination folder."""

    while True:
        date_input = input(f"Event date [YYYY-MM-DD] (default {default_date}): ").strip()
        if not date_input:
            date_input = default_date
        try:
            datetime.strptime(date_input, "%Y-%m-%d")
            break
        except ValueError:
            print("Invalid date. Please use YYYY-MM-DD.")

    while True:
        title_input = input("Event title: ").strip()
        if title_input:
            break
        print("Event title cannot be blank.")

    folder_name = f"{date_input}_{_slugify_segment(title_input)}"
    print(f"Using event folder '{folder_name}'.")
    return folder_name, date_input, title_input


def parse_args():
    parser = argparse.ArgumentParser(description="Sort ski videos with mpv previews.")
    parser.add_argument(
        "--source",
        default=SOURCE,
        help="Directory containing the raw videos (default: %(default)s)",
    )
    parser.add_argument(
        "--dest",
        default=None,
        help="Directory where organized videos will be stored (default: <source>/organized)",
    )
    parser.add_argument(
        "--window-width",
        type=int,
        default=None,
        help="Optional mpv window width in pixels",
    )
    parser.add_argument(
        "--window-height",
        type=int,
        default=None,
        help="Optional mpv window height in pixels",
    )
    parser.add_argument(
        "--resize",
        action="store_true",
        help="Kick off background resize jobs for each sorted video",
    )
    parser.add_argument(
        "--resize-dest",
        default=None,
        help="Root directory for resized output (default: <dest>_resized)",
    )
    sig = inspect.signature(resize_video_file)
    for name, param in sig.parameters.items():
        if name in _RESIZE_SKIP_PARAMS:
            continue
        ptype = _resize_param_type(param)
        default = param.default if param.default is not inspect.Parameter.empty else None
        parser.add_argument(
            f"--resize-{name.replace('_', '-')}",
            type=ptype,
            default=None,
            metavar=ptype.__name__.upper(),
            help=f"Passed to resize_video_file as {name!r} (default: {default})",
        )
    return parser.parse_args()


class NameCompleter:
    def __init__(self, names: List[str]):
        self.names = names

    def _matches(self, text: str) -> List[str]:
        if not text:
            return self.names
        lowered = text.lower()
        return [name for name in self.names if lowered in name.lower()]

    def complete(self, text: str, state: int):
        matches = self._matches(text)
        try:
            return matches[state]
        except IndexError:
            return None


def setup_name_autocomplete(names: List[str]):
    if not readline or not names:
        return None

    completer = NameCompleter(names)
    readline.set_completer(completer.complete)

    def _show_matches(substitution, matches, longest):  # pragma: no cover (interactive)
        if not matches:
            return
        preview = ", ".join(matches[:5])
        print(f"\nSuggestions: {preview}")
        try:
            readline.redisplay()
        except Exception:
            pass

    if readline.__doc__ and "libedit" in readline.__doc__:
        readline.parse_and_bind("bind ^I rl_complete")
    else:
        readline.parse_and_bind("tab: complete")

    return completer


class TerminalKeyListener:
    """Reads key presses from the active terminal in raw mode."""

    ESCAPE_MAP = {
        b"\x1b[A": "UP",
        b"\x1b[B": "DOWN",
        b"\x1b[C": "RIGHT",
        b"\x1b[D": "LEFT",
        b"\x1b[5~": "PAGE_UP",
        b"\x1b[6~": "PAGE_DOWN",
    }

    def __init__(self, handler):
        self.handler = handler
        self.fd = None
        self.orig_term = None
        self.running = False
        self.thread = None
        self.buffer = b""
        self.buffer_time = 0.0

    def start(self) -> bool:
        if self.running:
            return True
        if not sys.stdin.isatty():
            print("⚠️ Terminal controls disabled because stdin is not a TTY.")
            return False
        self.fd = sys.stdin.fileno()
        self.orig_term = termios.tcgetattr(self.fd)
        tty.setcbreak(self.fd)
        self.running = True
        self.thread = threading.Thread(target=self._loop, name="terminal-keys", daemon=True)
        self.thread.start()
        return True

    def stop(self):
        if not self.running:
            return
        self.running = False
        if self.thread:
            self.thread.join(timeout=0.5)
            self.thread = None
        if self.orig_term is not None and self.fd is not None:
            termios.tcsetattr(self.fd, termios.TCSADRAIN, self.orig_term)
        self.orig_term = None
        self.fd = None
        self.buffer = b""
        self.buffer_time = 0.0

    def _loop(self):
        assert self.fd is not None
        while self.running:
            rlist, _, _ = select.select([self.fd], [], [], 0.05)
            if not rlist:
                self._flush_buffer_if_stale()
                continue
            chunk = os.read(self.fd, 1)
            if not chunk:
                continue
            self._process_byte(chunk)

    def _flush_buffer_if_stale(self):
        if not self.buffer:
            return
        if time.time() - self.buffer_time > 0.15:
            pending = self.buffer
            self.buffer = b""
            for byte in pending:
                self._emit_char(bytes([byte]))

    def _process_byte(self, byte: bytes):
        if not byte:
            return
        if not self.buffer and byte != b"\x1b":
            self._emit_char(byte)
            return

        if not self.buffer:
            self.buffer = byte
            self.buffer_time = time.time()
            return

        self.buffer += byte
        self.buffer_time = time.time()
        match = self.ESCAPE_MAP.get(self.buffer)
        if match:
            self._emit_token(match)
            self.buffer = b""
            return

        if not any(seq.startswith(self.buffer) for seq in self.ESCAPE_MAP):
            pending = self.buffer
            self.buffer = b""
            for b in pending:
                self._emit_char(bytes([b]))

    def _emit_char(self, byte: bytes):
        if byte in (b"\r", b"\n"):
            self._emit_token("ENTER")
        elif byte == b"\x03":  # Ctrl+C
            self._emit_token("CTRL_C")
        elif byte == b"\x1b":
            self._emit_token("ESC")
        else:
            try:
                char = byte.decode("utf-8")
            except UnicodeDecodeError:
                return
            self._emit_token(char)

    def _emit_token(self, token):
        if self.handler:
            self.handler(token)


class MPVController:
    """Thin wrapper around mpv's IPC interface."""

    def __init__(self, window_width: Optional[int] = None, window_height: Optional[int] = None):
        self.proc: Optional[subprocess.Popen] = None
        self.speed = 1.0
        self.socket_path = os.path.join(tempfile.gettempdir(), f"mpv-sorter-{os.getpid()}.sock")
        self.log_path = os.path.join(tempfile.gettempdir(), f"mpv-sorter-{os.getpid()}.log")
        self.log_handle = None
        self.window_width = window_width if window_width and window_width > 0 else None
        self.window_height = window_height if window_height and window_height > 0 else None
        atexit.register(self.terminate)

    def _cleanup_socket(self):
        if os.path.exists(self.socket_path):
            os.remove(self.socket_path)

    def _mark_dead(self):
        self.proc = None
        if self.log_handle and not self.log_handle.closed:
            self.log_handle.close()
        self.log_handle = None
        self._cleanup_socket()

    def _ensure_process(self):
        if self.proc and self.proc.poll() is None:
            return

        self._cleanup_socket()
        if self.log_handle and not self.log_handle.closed:
            self.log_handle.close()
        self.log_handle = open(self.log_path, "a", encoding="utf-8")

        cmd = [
            "mpv",
            "--force-window=yes",
            "--idle=yes",
            "--keep-open=yes",
            "--input-vo-keyboard=no",
            f"--input-ipc-server={self.socket_path}",
        ]

        if self.window_width and self.window_height:
            cmd.append(f"--geometry={self.window_width}x{self.window_height}")

        try:
            self.proc = subprocess.Popen(
                cmd,
                stdout=self.log_handle,
                stderr=subprocess.STDOUT,
            )
        except FileNotFoundError:
            raise RuntimeError("mpv executable not found. Install mpv and ensure it is on PATH.")

        deadline = time.time() + 5.0
        while time.time() < deadline:
            if os.path.exists(self.socket_path):
                return
            if self.proc.poll() is not None:
                self._mark_dead()
                raise RuntimeError("mpv exited early. Check the log file for details.")
            time.sleep(0.05)
        self._mark_dead()
        raise TimeoutError("Timed out while waiting for the mpv IPC socket.")

    def _send(self, payload) -> dict:
        self._ensure_process()
        message = json.dumps(payload).encode("utf-8") + b"\n"
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            sock.settimeout(1.0)
            sock.connect(self.socket_path)
            sock.sendall(message)
            data = self._read_response(sock)
        except (FileNotFoundError, ConnectionRefusedError, socket.timeout):
            self._mark_dead()
            data = {}
        finally:
            sock.close()
        return data

    def _read_response(self, sock: socket.socket) -> dict:
        try:
            payload = sock.recv(4096)
        except socket.timeout:
            return {}
        if not payload:
            return {}
        line = payload.split(b"\n", 1)[0]
        try:
            return json.loads(line.decode("utf-8"))
        except json.JSONDecodeError:
            return {}

    def load(self, path: str):
        self.speed = 1.0
        return self._send({"command": ["loadfile", path, "replace"]})

    def wait_until_active(self, timeout: float = 5.0) -> bool:
        deadline = time.time() + timeout
        while time.time() < deadline:
            idle = self.get_property("idle-active")
            if idle is False:
                return True
            time.sleep(0.05)
        return False

    def get_property(self, name: str):
        response = self._send({"command": ["get_property", name]})
        return response.get("data")

    def seek(self, seconds: float):
        self._send({"command": ["seek", seconds, "relative"]})

    def frame_step(self):
        self._send({"command": ["frame-step"]})

    def frame_back_step(self):
        self._send({"command": ["frame-back-step"]})

    def toggle_slowmo(self):
        new_speed = 0.5 if self.speed == 1.0 else 1.0
        self.speed = new_speed
        self._send({"command": ["set", "speed", new_speed]})

    def stop(self):
        self._send({"command": ["stop"]})

    def terminate(self):
        if self.proc is None:
            self._mark_dead()
            return

        try:
            self._send({"command": ["quit"]})
        except Exception:
            pass
        try:
            self.proc.terminate()
            self.proc.wait(timeout=2)
        except Exception:
            pass
        self._mark_dead()

class SkiSorter:
    def __init__(
        self,
        source_dir: str,
        dest_dir: str,
        event_folder: str,
        event_date: str,
        event_title: str,
        window_width: Optional[int] = None,
        window_height: Optional[int] = None,
        resize_dest: Optional[str] = None,
        resize_kwargs: Optional[dict] = None,
    ):
        self.source_dir = source_dir
        self.dest_dir = dest_dir
        self.event_folder = event_folder
        self.event_date = event_date
        self.event_title = event_title
        self.resize_dest = resize_dest
        self.resize_kwargs = resize_kwargs or {}
        self.player = MPVController(window_width, window_height)
        self.names = load_name_list(NAMES_PATH)
        self.exact_name_map = {name.lower(): name for name in self.names}
        self.name_index = [(name, name.lower()) for name in self.names]
        self.name_completer = setup_name_autocomplete(self.names)
        if NAMES_PATH and os.path.exists(NAMES_PATH) and not self.names:
            print(f"⚠️ No usable names found in {NAMES_PATH}. Autocomplete disabled.")
        
        self.files: List[str] = []
        self.current_index = 0
        self.current_file: Optional[str] = None
        self.switch_event = threading.Event()
        self.tag_event = threading.Event()
        self.wake_event = threading.Event()
        self.quit_requested = False
        self.key_listener = TerminalKeyListener(self._handle_key_token)
        self.keys_active = False
        self._resize_jobs: List[threading.Thread] = []
        self._resize_lock = threading.Lock()
        self._resize_errors: List[str] = []

    def _start_terminal_keys(self):
        if self.keys_active:
            return
        if self.key_listener.start():
            self.keys_active = True

    def _stop_terminal_keys(self):
        if not self.keys_active:
            return
        self.key_listener.stop()
        self.keys_active = False

    def _wake(self):
        self.wake_event.set()

    def _handle_key_token(self, token):
        if self.quit_requested or not self.keys_active:
            return

        actions = {
            'RIGHT': lambda: self.player.seek(1),
            'LEFT': lambda: self.player.seek(-1),
            'PAGE_UP': lambda: self.player.seek(-5),
            'PAGE_DOWN': lambda: self.player.seek(5),
            'UP': lambda: self._navigate(-1),
            'DOWN': lambda: self._navigate(1),
            'ENTER': self._request_tagging,
            'ESC': self._request_quit,
            'CTRL_C': self._request_quit,
        }

        action = actions.get(token)
        if action:
            action()
            return

        if isinstance(token, str) and len(token) == 1:
            ch = token
            if ch == '.':
                self.player.frame_step()
            elif ch == ',':
                self.player.frame_back_step()
            elif ch.lower() == 's':
                self.player.toggle_slowmo()
            elif ch.lower() == 'q':
                self._request_quit()

    def _request_quit(self):
        self.quit_requested = True
        self.tag_event.set()
        self.switch_event.set()
        self.player.stop()
        self._wake()

    def _navigate(self, delta: int):
        if not self.files:
            return
        if self.tag_event.is_set():
            return
        new_index = self.current_index + delta
        new_index = max(0, min(len(self.files) - 1, new_index))
        if new_index == self.current_index:
            return
        self.current_index = new_index
        self.current_file = self.files[self.current_index]
        self.switch_event.set()
        self.player.stop()
        self._wake()

    def _advance_index(self, delta: int):
        if not self.files:
            return
        self.current_index = (self.current_index + delta) % len(self.files)
        self.current_file = self.files[self.current_index]
        self.switch_event.set()
        self._wake()

    def _remove_current(self):
        if not self.files:
            return
        self.files.pop(self.current_index)
        if self.current_index >= len(self.files):
            self.current_index = max(0, len(self.files) - 1)
        self.current_file = None if not self.files else self.files[self.current_index]
        self.switch_event.set()
        self._wake()

    def _auto_complete_name(self, typed: str) -> Tuple[str, bool, List[str]]:
        if not typed:
            return "", False, self.names
        lowered = typed.lower()
        matches = [name for name in self.names if lowered in name.lower()]
        exact_matches = [name for name in matches if name.lower() == lowered]
        if exact_matches:
            return exact_matches[0], True, matches
        if len(matches) == 1:
            return matches[0], True, matches
        return typed, False, matches

    def _render_prompt_line(self, prompt: str, value: str, prev_len: int) -> int:
        sys.stdout.write("\r")
        sys.stdout.write(prompt + value)
        clear = max(0, prev_len - len(value))
        if clear:
            sys.stdout.write(" " * clear)
        sys.stdout.flush()
        return len(value)

    def _interactive_name_input(self, prompt: str) -> str:
        if not sys.stdin.isatty():
            return input(prompt)

        fd = sys.stdin.fileno()
        orig_term = termios.tcgetattr(fd)
        tty.setcbreak(fd)
        typed = ""
        display = ""
        prev_len = 0
        sys.stdout.write(prompt)
        sys.stdout.flush()

        try:
            while True:
                chunk = os.read(fd, 1)
                if not chunk:
                    continue
                if chunk in (b"\r", b"\n"):
                    sys.stdout.write("\n")
                    sys.stdout.flush()
                    return display.strip()
                if chunk in (b"\x7f", b"\b"):
                    if typed:
                        typed = typed[:-1]
                    display, _, _ = self._auto_complete_name(typed)
                    prev_len = self._render_prompt_line(prompt, display, prev_len)
                    continue
                if chunk == b"\x03":
                    raise KeyboardInterrupt
                if chunk == b"\x04":  # Ctrl+D
                    sys.stdout.write("\n")
                    sys.stdout.flush()
                    return ""
                if chunk == b"\x1b":
                    consumed = False
                    while True:
                        rlist, _, _ = select.select([fd], [], [], 0.003)
                        if not rlist:
                            if not consumed:
                                sys.stdout.write("\n")
                                sys.stdout.flush()
                                return ""
                            break
                        consumed = True
                        os.read(fd, 1)
                    continue
                if chunk == b"\t":
                    display, matched, matches = self._auto_complete_name(typed)
                    if matched:
                        typed = display
                    prev_len = self._render_prompt_line(prompt, display, prev_len)
                    if matches:
                        sys.stdout.write("\nSuggestions:\n")
                        for name in matches:
                            sys.stdout.write(f"  {name}\n")
                        prev_len = self._render_prompt_line(prompt, display, 0)
                    continue
                try:
                    char = chunk.decode("utf-8")
                except UnicodeDecodeError:
                    continue
                typed += char
                display, _, _ = self._auto_complete_name(typed)
                prev_len = self._render_prompt_line(prompt, display, prev_len)
        finally:
            termios.tcsetattr(fd, termios.TCSADRAIN, orig_term)

    def _load_current_video(self) -> bool:
        if not self.files:
            return False
        filename = self.files[self.current_index]
        path = os.path.join(self.source_dir, filename)
        if not os.path.exists(path):
            print(f"⚠️ Missing file: {path}")
            self._remove_current()
            return False

        self.current_file = filename
        self.player.load(path)
        if not self.player.wait_until_active():
            print(f"⚠️ mpv did not start playback for {filename}. Check the log output above.")
            return False

        self._print_controls(filename)
        return True

    def _print_controls(self, filename: str):
        remaining = len(self.files)
        print(f"\n--- Sorting ({self.current_index + 1}/{remaining}): {filename} ---")
        print("Controls: ←/→ (±1s) | PgUp/Dn (±5s) | </> Frames | 's' Slow-mo")
        print("Use ↓/↑ to move to next/previous video, Enter to tag, Esc/Q to quit.")

    def _prompt_for_tag(self):
        if self.current_file is None:
            return
        if self.names:
            sample = ", ".join(self.names[:5])
            print(f"Type the full athlete name; Tab lists matches. Examples: {sample}")
        try:
            if self.names:
                athlete_input = self._interactive_name_input("Enter Athlete Name (blank = skip, :q to quit): ")
            else:
                athlete_input = input("Enter Athlete Name (blank = skip, :q to quit): ")
        except KeyboardInterrupt:
            print("\nSession interrupted (Ctrl+C).")
            self.quit_requested = True
            return
        except EOFError:
            athlete_input = ""

        if athlete_input.strip().lower() in {":q", "q", "quit"}:
            self.quit_requested = True
            self._wake()
            return

        athlete = self._resolve_athlete_name(athlete_input)
        path = os.path.join(self.source_dir, self.current_file)
        if not os.path.exists(path):
            print(f"⚠️ Missing file: {path}")
            self._remove_current()
            return

        if athlete:
            target_dir = os.path.join(self.dest_dir, self.event_folder, athlete.title())
            os.makedirs(target_dir, exist_ok=True)
            moved_path = os.path.join(target_dir, self.current_file)
            shutil.move(path, moved_path)
            print(f"✅ Moved {self.current_file} to {athlete.title()}")
            if self.resize_dest:
                resize_athlete_dir = os.path.join(self.resize_dest, self.event_folder, athlete.title())
                self._start_resize_job(moved_path, resize_athlete_dir, self.current_file)
            self._remove_current()
        else:
            print(f"⏭️ Skipped {self.current_file}")
            self._advance_index(1)

        self.player.stop()
        self._wake()

    def _request_tagging(self):
        if self.current_file is None or self.tag_event.is_set():
            return
        self.tag_event.set()
        self._wake()

    def _resolve_athlete_name(self, raw_name: str) -> str:
        name = raw_name.strip()
        if not name:
            return ""
        if not self.names:
            return name.title()

        lowered = name.lower()
        exact = self.exact_name_map.get(lowered)
        if exact:
            return exact

        matches = [orig for orig, lower in self.name_index if lowered in lower]
        if len(matches) == 1:
            return matches[0]
        if 1 < len(matches) <= 5:
            print("Suggestions:", ", ".join(matches))
        return name.title()

    def _resize_worker(self, moved_path: str, resize_athlete_dir: str, filename: str):
        try:
            os.makedirs(resize_athlete_dir, exist_ok=True)
            result = resize_video_file(moved_path, **self.resize_kwargs)
            final_path = os.path.join(resize_athlete_dir, filename)
            shutil.move(str(result.output), final_path)
            print(f"\n[resize] Done: {filename} -> {resize_athlete_dir}")
        except Exception as exc:
            with self._resize_lock:
                self._resize_errors.append(f"{filename}: {exc}")
            print(f"\n[resize] Failed {filename}: {exc}")

    def _start_resize_job(self, moved_path: str, resize_athlete_dir: str, filename: str):
        thread = threading.Thread(
            target=self._resize_worker,
            args=(moved_path, resize_athlete_dir, filename),
            daemon=True,
            name=f"resize-{filename}",
        )
        with self._resize_lock:
            self._resize_jobs.append(thread)
        thread.start()
        print(f"[resize] Started background job for {filename}")

    def _wait_for_resize_jobs(self):
        with self._resize_lock:
            jobs = list(self._resize_jobs)
        if not jobs:
            return
        pending = [j for j in jobs if j.is_alive()]
        if pending:
            print(f"\nWaiting for {len(pending)} resize job(s) to complete...")
            for job in pending:
                job.join()
        if self._resize_errors:
            print(f"\n{len(self._resize_errors)} resize error(s):")
            for err in self._resize_errors:
                print(f"  {err}")
        else:
            print(f"\nAll {len(jobs)} resize job(s) completed successfully.")

    def run(self):
        if not os.path.exists(self.source_dir):
            print(f"Source directory not found: {self.source_dir}")
            return

        if not os.path.exists(self.dest_dir):
            os.makedirs(self.dest_dir)

        event_root = os.path.join(self.dest_dir, self.event_folder)
        os.makedirs(event_root, exist_ok=True)
        print(f"Destination event folder: {event_root}")
        print(f"Event: {self.event_title} on {self.event_date}")
        
        # Get videos
        valid_exts = ('.mp4', '.mov', '.m4v')
        files = [f for f in os.listdir(self.source_dir) if f.lower().endswith(valid_exts)]
        print(f"Found {len(files)} videos to sort.")
        if not files:
            print(f"No videos found in {self.source_dir}!")
            return

        self.files = sorted(files)
        self.current_index = 0
        self.current_file = None
        self.switch_event.set()
        self._wake()
        self._start_terminal_keys()

        try:
            while self.files and not self.quit_requested:
                if self.switch_event.is_set():
                    self.switch_event.clear()
                    if not self.files:
                        break
                    if not self._load_current_video():
                        continue
                if self.tag_event.is_set():
                    self.tag_event.clear()
                    self._stop_terminal_keys()
                    self._prompt_for_tag()
                    if self.quit_requested:
                        break
                    self._start_terminal_keys()
                    continue
                self.wake_event.wait()
                self.wake_event.clear()
        except KeyboardInterrupt:
            self.quit_requested = True
            print("\nSession interrupted (Ctrl+C).")
        finally:
            self._stop_terminal_keys()
            self.player.terminate()

        if self.quit_requested:
            print("\nSession ended by user.")
        else:
            print("\nAll done!")
        self._wait_for_resize_jobs()

if __name__ == "__main__":
    cli_args = parse_args()
    source_dir = resolve_path(cli_args.source)
    if cli_args.dest:
        dest_dir = resolve_path(cli_args.dest)
    else:
        dest_dir = os.path.join(source_dir, "organized")
    window_width = cli_args.window_width if cli_args.window_width and cli_args.window_width > 0 else None
    window_height = cli_args.window_height if cli_args.window_height and cli_args.window_height > 0 else None
    resize_dest = None
    resize_kwargs = {}
    if cli_args.resize:
        if cli_args.resize_dest:
            resize_dest = resolve_path(cli_args.resize_dest)
        else:
            resize_dest = dest_dir + "_resized"
        for name in inspect.signature(resize_video_file).parameters:
            if name in _RESIZE_SKIP_PARAMS:
                continue
            value = getattr(cli_args, f"resize_{name}", None)
            if value is not None:
                resize_kwargs[name] = value
    default_event_date = detect_default_event_date(source_dir)
    event_folder, event_date, event_title = prompt_event_folder(default_event_date)
    sorter = SkiSorter(
        source_dir,
        dest_dir,
        event_folder,
        event_date,
        event_title,
        window_width,
        window_height,
        resize_dest,
        resize_kwargs,
    )
    sorter.run()