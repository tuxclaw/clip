import importlib.util
import json
from pathlib import Path
import sys

# -I excludes the script directory from sys.path. Load only our bundled helper,
# without adding cwd, PYTHONPATH, or user site directories to the import path.
_spec = importlib.util.spec_from_file_location("clip_safe_io", Path(__file__).resolve().with_name("safe_io.py"))
_safe_io = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_safe_io)
atomic_write, read_bytes = _safe_io.atomic_write, _safe_io.read_bytes

MAX_BYTES = 2 * 1024 * 1024
MAX_ENTRIES = 500
MAX_STDIN_BYTES = 64 * 1024


def normalize(value):
    if isinstance(value, str):
        value = {"type": "text", "text": value}
    if not isinstance(value, dict):
        return None
    if value.get("type") == "text" and isinstance(value.get("text"), str):
        return {"type": "text", "text": value["text"]} if value["text"].strip() else None
    if value.get("type") == "image" and isinstance(value.get("path"), str) and value["path"]:
        entry = {"type": "image", "path": value["path"], "mime": str(value.get("mime") or "image/png")}
        if value.get("capturedAt") is not None:
            entry["capturedAt"] = str(value["capturedAt"])
        return entry
    return None


def key(entry):
    return "image:" + entry["path"] if entry["type"] == "image" else "text:" + entry["text"]


def validate_entries(values):
    if not isinstance(values, list) or len(values) > MAX_ENTRIES:
        raise ValueError(f"Expected an array of at most {MAX_ENTRIES} entries")
    return values


def read(path, default):
    try:
        raw = read_bytes(path, MAX_BYTES)
    except FileNotFoundError:
        return default, None
    return validate_entries(json.loads(raw)), raw


def update(path, transform):
    for _ in range(5):
        values, before = read(path, [])
        result = validate_entries(transform(values))
        data = (json.dumps(result, ensure_ascii=False, indent=2) + "\n").encode("utf-8")
        if len(data) > MAX_BYTES:
            raise ValueError("Output exceeds byte limit")
        if read(path, [])[1] != before:
            continue
        atomic_write(path, data, max_bytes=MAX_BYTES)
        return
    raise RuntimeError("History changed repeatedly; please try again")


def dump(state):
    history = read(state / "clipboard-history.json", [])[0]
    pins = read(state / "clip-pins.json", [])[0]
    if not all(isinstance(value, str) for value in pins):
        raise ValueError("Invalid pins file")
    # Preserve raw history positions used by the stock clipboard commands.
    return {"history": history, "pins": pins}


def read_payload(stream):
    raw = stream.readline(MAX_STDIN_BYTES + 1)
    if len(raw) > MAX_STDIN_BYTES:
        raise ValueError("Mutation input exceeds byte limit")
    return json.loads(raw)


def dump_bytes(state):
    data = (json.dumps(dump(state), ensure_ascii=False) + "\n").encode("utf-8")
    if len(data) > MAX_BYTES:
        raise ValueError("Output exceeds byte limit")
    return data


def mutate(state, operation, payload):
    if operation == "pin":
        identity = payload["identity"]
        if not isinstance(identity, str) or not identity.startswith(("text:", "image:")):
            raise ValueError("Invalid pin")
        def pin(values):
            if not isinstance(values, list) or not all(isinstance(v, str) for v in values):
                raise ValueError("Invalid pins file")
            return [v for v in values if v != identity] if identity in values else values + [identity]
        update(state / "clip-pins.json", pin)
        return
    if operation not in ("delete", "clear"):
        raise ValueError("Unknown operation")
    targets = {payload["identity"]} if operation == "delete" else set(payload["identities"])
    def remove(values):
        if not isinstance(values, list):
            raise ValueError("Invalid history file")
        entries = [normalize(value) for value in values]
        return [entry for entry in entries if entry is not None and key(entry) not in targets]
    update(state / "clipboard-history.json", remove)


if __name__ == "__main__":
    try:
        state = Path.home() / ".local/state/omarchy"
        if sys.argv[1] == "dump":
            sys.stdout.buffer.write(dump_bytes(state))
        else:
            mutate(state, sys.argv[1], read_payload(sys.stdin.buffer))
    except Exception as error:
        print("Clip storage failed: " + str(error)[:4096], file=sys.stderr)
        sys.exit(1)
