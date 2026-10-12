#!/usr/bin/env python3
"""Remove the live guard and enforce ProjectWriting's restart cleanup policy."""
import argparse
import os
import re
import stat
import sys
import subprocess
import tempfile
from dataclasses import dataclass
from pathlib import Path

GUARD_PARTS = ("media", "lua", "server")
# Legacy auto-loaded server files participate in client checksums. The guard is
# injected after the static server sandbox table, which loads after checksums.
GUARD_NAME = "PZManagerWritingTextOnlySandboxVars.lua"
LEGACY_GUARD_NAME = "PZManagerWritingTextOnly.lua"

def namespace_root_uid():
    # PrivateTmp on an unprivileged user service maps root-owned ancestors to
    # the overflow UID. Compare with the actual namespace root, not host UID 0.
    return os.stat("/").st_uid

def trusted_owner(uid):
    return uid in (os.getuid(), namespace_root_uid())

class ConfigurationError(ValueError):
    pass

@dataclass
class Token:
    kind: str
    value: str
    start: int
    end: int

@dataclass
class Value:
    kind: str
    start: int
    end: int
    entries: dict | None = None
    closing: int | None = None
    trailing_delimiter: bool = False


def lex(text):
    """Tokenize Lua without interpreting strings or comments as punctuation."""
    tokens = []
    pos = 0
    while pos < len(text):
        if text[pos].isspace():
            pos += 1
            continue
        start = pos
        comment = text.startswith("--", pos)
        if comment:
            pos += 2
        long = re.match(r"\[(=*)\[", text[pos:])
        if long:
            ending = "]" + long[1] + "]"
            finish = text.find(ending, pos + len(long[0]))
            if finish < 0:
                raise ConfigurationError("Unterminated Lua long string/comment")
            pos = finish + len(ending)
            if not comment:
                tokens.append(Token("string", text[start:pos], start, pos))
            continue
        if comment:
            finish = text.find("\n", pos)
            pos = len(text) if finish < 0 else finish
            continue
        if text[pos] in "\"'":
            quote = text[pos]
            pos += 1
            while pos < len(text):
                if text[pos] == "\\":
                    pos += 2
                elif text[pos] == quote:
                    pos += 1
                    break
                elif text[pos] in "\r\n":
                    raise ConfigurationError("Unescaped newline in Lua string")
                else:
                    pos += 1
            else:
                raise ConfigurationError("Unterminated Lua string")
            if pos > len(text):
                raise ConfigurationError("Truncated Lua escape")
            tokens.append(Token("string", text[start:pos], start, pos))
            continue
        ident = re.match(r"[A-Za-z_][A-Za-z_0-9]*", text[pos:])
        if ident:
            pos += len(ident[0]); tokens.append(Token("identifier", ident[0], start, pos)); continue
        number = re.match(r"(?:0[xX][0-9a-fA-F]+|(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?)", text[pos:])
        if number:
            pos += len(number[0]); tokens.append(Token("number", number[0], start, pos)); continue
        if text[pos] in "{}[]=,;+-":
            pos += 1; tokens.append(Token(text[start:pos], text[start:pos], start, pos)); continue
        raise ConfigurationError(f"Unsupported Lua syntax at character {pos}")
    return tokens


def string_key(raw):
    if raw.startswith("["):
        opening = re.match(r"\[(=*)\[", raw)[0]
        content = raw[len(opening):-len(opening)].replace("\r\n", "\n").replace("\r", "\n")
        return content[1:] if content.startswith("\n") else content
    content = raw[1:-1]
    # Generated keys are normally identifiers. Decode common Lua escaped keys
    # so e.g. ["Free\\104and"] cannot evade duplicate-key detection.
    result = []
    pos = 0
    escapes = {"a": "\a", "b": "\b", "f": "\f", "n": "\n", "r": "\r", "t": "\t", "v": "\v", "\\": "\\", '"': '"', "'": "'"}
    while pos < len(content):
        if content[pos] != "\\": result.append(content[pos]); pos += 1; continue
        pos += 1
        if pos >= len(content): raise ConfigurationError("Malformed escaped Lua key")
        numeric = re.match(r"\d{1,3}", content[pos:])
        if numeric:
            n = int(numeric[0])
            if n > 255: raise ConfigurationError("Invalid decimal Lua key escape")
            result.append(chr(n)); pos += len(numeric[0]); continue
        escape = content[pos]
        if escape not in escapes: raise ConfigurationError("Unsupported escaped Lua key")
        result.append(escapes[escape]); pos += 1
    return "".join(result)


class StaticTableParser:
    def __init__(self, tokens): self.tokens = tokens; self.pos = 0
    def peek(self): return self.tokens[self.pos] if self.pos < len(self.tokens) else None
    def take(self, kind=None):
        token = self.peek()
        if token is None or kind is not None and token.kind != kind:
            raise ConfigurationError("Malformed static SandboxVars table")
        self.pos += 1
        return token
    def value(self):
        token = self.peek()
        if token is None: raise ConfigurationError("Missing Lua option value")
        if token.kind == "{": return self.table()
        if token.kind in ("+", "-"):
            start = self.take().start; n = self.take("number"); return Value("number", start, n.end)
        if token.kind in ("string", "number") or token.kind == "identifier" and token.value in ("true", "false", "nil"):
            self.take(); return Value(token.value if token.kind == "identifier" else token.kind, token.start, token.end)
        raise ConfigurationError("Dynamic Lua option values are not supported")
    def table(self):
        opening = self.take("{"); entries = {}; ordinal = 1; trailing = False
        while self.peek() is not None and self.peek().kind != "}":
            token = self.peek()
            if token.kind == "identifier" and self.pos + 1 < len(self.tokens) and self.tokens[self.pos + 1].kind == "=":
                key = self.take().value; self.take("=")
            elif token.kind == "[":
                self.take("["); kt = self.take()
                if kt.kind == "string": key = string_key(kt.value)
                elif kt.kind == "number":
                    try: key = float(kt.value)
                    except ValueError: raise ConfigurationError("Unsupported numeric table key")
                else: raise ConfigurationError("Dynamic Lua option keys are not supported")
                self.take("]"); self.take("=")
            else:
                key = ordinal; ordinal += 1
            if key in entries: raise ConfigurationError(f"Duplicate Lua table key: {key}")
            entries[key] = self.value()
            next_token = self.peek()
            if next_token is not None and next_token.kind in (",", ";"):
                self.take(); trailing = True
            elif next_token is not None and next_token.kind == "}": trailing = False
            else: raise ConfigurationError("Missing Lua field separator or dynamic expression")
        close = self.take("}")
        return Value("table", opening.start, close.end, entries, close.start, trailing)
    def sandbox(self):
        first = self.take("identifier")
        if first.value != "SandboxVars": raise ConfigurationError("Expected static SandboxVars assignment")
        self.take("="); root = self.table()
        if self.peek() is not None and self.peek().kind == ";": self.take()
        if self.peek() is not None: raise ConfigurationError("Unexpected Lua statements after SandboxVars")
        return root


def add_fields(text, table, fields):
    """Insert before closing brace, retaining all original comments and options."""
    if not fields: return text
    line_start = text.rfind("\n", 0, table.closing) + 1
    close_prefix = text[line_start:table.closing]
    close_indent = close_prefix if not close_prefix.strip() else ""
    indentation = close_indent + "    "
    # Existing option indent makes the smallest visually consistent addition.
    if table.entries:
        first = next(iter(table.entries.values()))
        keyline = text.rfind("\n", 0, first.start) + 1
        match = re.match(r"[ \t]*", text[keyline:first.start])
        if match and match[0]: indentation = match[0]
    newline = "\r\n" if "\r\n" in text else "\n"
    delimiter = "" if not table.entries or table.trailing_delimiter else ","
    insertion = delimiter + newline + newline.join(indentation + field + "," for field in fields) + newline + close_indent
    # Insert at the closing brace itself; its original indentation is preserved.
    return text[:table.closing] + insertion + text[table.closing:]


def enforce_sandbox(text):
    root = StaticTableParser(lex(text)).sandbox()
    block = root.entries.get("ProjectWriting")
    if block is None:
        result = add_fields(text, root, ["ProjectWriting = { Freehand = false, VanillaMap = true }"])
    else:
        if block.kind != "table": raise ConfigurationError("ProjectWriting must be a static table")
        changes = []; missing = []
        for key, desired in (("Freehand", "false"), ("VanillaMap", "true")):
            existing = block.entries.get(key)
            if existing is None: missing.append(key + " = " + desired)
            elif existing.kind not in ("true", "false"):
                raise ConfigurationError(f"ProjectWriting.{key} must be boolean")
            elif existing.kind != desired: changes.append((existing.start, existing.end, desired))
        result = text
        if missing: changes.append((block.closing, block.closing, add_fields(text, block, missing)[block.closing:-len(text[block.closing:])] if text[block.closing:] else ""))
        for start, end, replacement in sorted(changes, reverse=True): result = result[:start] + replacement + result[end:]
    # Parse our output again and verify the enforced state before any write.
    verify = StaticTableParser(lex(result)).sandbox().entries["ProjectWriting"]
    if verify.entries["Freehand"].kind != "false" or verify.entries["VanillaMap"].kind != "true":
        raise ConfigurationError("Sandbox enforcement postcondition failed")
    return result


def read_regular(path):
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
        with os.fdopen(fd, "rb") as stream:
            info = os.fstat(stream.fileno())
            if not stat.S_ISREG(info.st_mode): raise ConfigurationError(f"Expected a regular file: {path}")
            return stream.read(), info
    except OSError as error:
        raise ConfigurationError(f"Cannot read regular file {path}: {error.strerror}") from error


def mod_enabled(ini):
    values = []
    for line in ini.splitlines():
        if not line.strip() or line.lstrip().startswith(("#", ";")): continue
        key, sep, value = line.partition("=")
        if sep and key.strip() == "Mods": values.append(value.strip())
    if len(values) > 1: raise ConfigurationError("Duplicate Mods settings in server INI")
    # B42 préfixe aussi les ID de mods communs par un antislash dans Mods=.
    # Accepter uniquement ces deux ID exacts, sans activer un mod voisin/retiré.
    return bool(values) and bool({"ProjectWriting", "\\ProjectWriting"} &
                                 {token.strip() for token in values[0].split(";")})


def validate_directory(fd, label, private_anchor=False):
    info = os.fstat(fd)
    if not stat.S_ISDIR(info.st_mode) or not trusted_owner(info.st_uid) or info.st_mode & 0o002 or (info.st_mode & 0o020 and not private_anchor):
        raise ConfigurationError(f"Directory can be replaced or written by another user: {label}")


def open_root(path):
    """Reject symlinks in the installation path and pin the owned root FD."""
    absolute = Path(os.path.abspath(path))
    fd = os.open("/", os.O_RDONLY | os.O_DIRECTORY)
    private_anchor = False
    try:
        for part in absolute.parts[1:]:
            next_fd = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            os.close(fd); fd = next_fd
            ancestor = os.fstat(fd)
            # Sticky shared ancestors such as /tmp cannot have an owned child
            # replaced by another UID. Non-sticky writable ancestors can.
            if not trusted_owner(ancestor.st_uid):
                raise ConfigurationError(f"Installation path ancestor is owned by another user: {part}")
            if ancestor.st_mode & 0o002 and not ancestor.st_mode & stat.S_ISVTX:
                raise ConfigurationError(f"World-writable installation path ancestor: {part}")
            if ancestor.st_mode & 0o020 and not private_anchor and not ancestor.st_mode & stat.S_ISVTX:
                raise ConfigurationError(f"Group-writable path lacks a private ancestor: {part}")
            if ancestor.st_uid == os.getuid() and not ancestor.st_mode & 0o077:
                private_anchor = True
        validate_directory(fd, absolute, private_anchor)
        return fd, private_anchor
    except Exception:
        os.close(fd); raise


def guard_parent(root_fd, create=False, private_anchor=False):
    fd = os.dup(root_fd)
    try:
        for part in GUARD_PARTS:
            try: next_fd = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            except FileNotFoundError:
                if not create: os.close(fd); return None
                os.mkdir(part, mode=0o755, dir_fd=fd)
                next_fd = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            os.close(fd); fd = next_fd; validate_directory(fd, part, private_anchor)
        return fd
    except Exception:
        os.close(fd); raise


def atomic_file(parent_fd, name, data, mode):
    temporary = "." + name + "." + next(tempfile._get_candidate_names())
    fd = None
    try:
        fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, mode, dir_fd=parent_fd)
        with os.fdopen(fd, "wb") as stream:
            fd = None; stream.write(data); stream.flush(); os.fchmod(stream.fileno(), mode); os.fsync(stream.fileno())
        os.replace(temporary, name, src_dir_fd=parent_fd, dst_dir_fd=parent_fd)
        os.fsync(parent_fd)
    finally:
        if fd is not None: os.close(fd)
        try: os.unlink(temporary, dir_fd=parent_fd)
        except FileNotFoundError: pass


BEGIN_MARKER = "-- PZMANAGER WRITING TEXT ONLY BEGIN"
END_MARKER = "-- PZMANAGER WRITING TEXT ONLY END"
LEGACY_GUARD_NAMES = ("PZManagerWritingTextOnly.lua", "PZManagerWritingTextOnlySandboxVars.lua")


def managed_marker_lines(text):
    """Recognize only actual Lua line comments, outside strings/long comments."""
    found = []
    pos = 0
    while pos < len(text):
        comment = text.startswith("--", pos)
        if comment:
            content_start = pos + 2
            long = re.match(r"\[(=*)\[", text[content_start:])
        else:
            content_start = pos
            long = re.match(r"\[(=*)\[", text[pos:])
        if long:
            ending = "]" + long[1] + "]"
            finish = text.find(ending, content_start + len(long[0]))
            if finish < 0: raise ConfigurationError("Unterminated Lua long string/comment")
            pos = finish + len(ending)
            continue
        if comment:
            finish = text.find("\n", pos)
            if finish < 0: finish = len(text)
            line_start = text.rfind("\n", 0, pos) + 1
            marker = text[pos:finish].rstrip("\r \t")
            if marker in (BEGIN_MARKER, END_MARKER):
                if text[line_start:pos].strip():
                    raise ConfigurationError("Managed guard marker must occupy its own line")
                found.append((marker, line_start, min(finish + 1, len(text))))
            pos = finish
            continue
        if text[pos] in "\"'":
            quote = text[pos]; pos += 1
            while pos < len(text):
                if text[pos] == "\\": pos += 2
                elif text[pos] == quote: pos += 1; break
                elif text[pos] in "\r\n": raise ConfigurationError("Unescaped newline in Lua string")
                else: pos += 1
            else: raise ConfigurationError("Unterminated Lua string")
            continue
        pos += 1
    return found


def strip_managed_guard(text):
    markers = managed_marker_lines(text)
    if not markers: return text
    if len(markers) != 2 or markers[0][0] != BEGIN_MARKER or markers[1][0] != END_MARKER:
        raise ConfigurationError("Ambiguous or incomplete managed guard block")
    _, start, body_start = markers[0]
    _, end, block_end = markers[1]
    # Prove the managed block follows a complete static assignment. Never
    # remove a comment-delimited section embedded within SandboxVars itself.
    StaticTableParser(lex(text[:start])).sandbox()
    return text[:start] + text[block_end:]


def append_managed_guard(base, guard):
    if managed_marker_lines(guard):
        raise ConfigurationError("Guard source contains reserved managed markers")
    newline = "\r\n" if "\r\n" in base else "\n"
    body = guard.replace("\r\n", "\n").replace("\r", "\n").rstrip("\n").replace("\n", newline)
    separator = "" if base.endswith(("\n", "\r")) else newline
    return base + separator + BEGIN_MARKER + newline + body + newline + END_MARKER + newline


def configure(install_dir, sandbox_file, ini_file, guard_source=None, mode=1):
    enabled = False
    if mode == 1:
        ini, _ = read_regular(ini_file)
        enabled = mod_enabled(ini.decode("utf-8"))
    root_fd, private_install_anchor = open_root(install_dir)
    guard_fd = None; sandbox_fd = None
    try:
        # Validate paths and legacy targets before mutation. Remove the old
        # managed Lua footer; no source guard or runtime callback is loaded.
        sandbox_path = Path(os.path.abspath(sandbox_file))
        old_sandbox = new_sandbox = None
        try:
            old_sandbox, info = read_regular(sandbox_path)
        except ConfigurationError:
            if enabled or sandbox_path.exists() or sandbox_path.is_symlink(): raise
        if old_sandbox is not None:
            base = strip_managed_guard(old_sandbox.decode("utf-8"))
            new_sandbox = (enforce_sandbox(base) if enabled else base).encode("utf-8")
            sandbox_fd, private_sandbox_anchor = open_root(sandbox_path.parent)
            if not trusted_owner(info.st_uid) or info.st_mode & 0o002 or (info.st_mode & 0o020 and not private_sandbox_anchor):
                raise ConfigurationError("Sandbox file can be written by another user")
        guard_fd = guard_parent(root_fd, create=False, private_anchor=private_install_anchor)
        if guard_fd is not None:
            for name in LEGACY_GUARD_NAMES:
                try: target = os.stat(name, dir_fd=guard_fd, follow_symlinks=False)
                except FileNotFoundError: continue
                if not stat.S_ISREG(target.st_mode) and not stat.S_ISLNK(target.st_mode):
                    raise ConfigurationError("Legacy guard target is not a regular file or symlink")
        if new_sandbox != old_sandbox:
            atomic_file(sandbox_fd, sandbox_path.name, new_sandbox, stat.S_IMODE(info.st_mode))
        if guard_fd is not None:
            for name in LEGACY_GUARD_NAMES:
                try: os.unlink(name, dir_fd=guard_fd)
                except FileNotFoundError: pass
        return "enabled" if enabled else "disabled"
    finally:
        if guard_fd is not None: os.close(guard_fd)
        if sandbox_fd is not None: os.close(sandbox_fd)
        os.close(root_fd)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--install-dir", required=True)
    parser.add_argument("--sandbox-file", required=True)
    parser.add_argument("--ini-file", required=True)
    parser.add_argument("--guard-source", help="Deprecated; no Lua guard is loaded")
    parser.add_argument("--cleanup-world")
    parser.add_argument("--cleanup-backups")
    parser.add_argument("--jar")
    parser.add_argument("--java")
    parser.add_argument("--javac")
    parser.add_argument("--mode", type=int, choices=(0, 1), default=1)
    args = parser.parse_args()
    try:
        if bool(args.cleanup_world) != bool(args.cleanup_backups):
            raise ConfigurationError("Both cleanup paths are required")
        worker_fd = None
        if args.cleanup_world:
            from writing_start_admission import validate_worker_admission
            worker_fd = validate_worker_admission()
        state = configure(args.install_dir, args.sandbox_file, args.ini_file, args.guard_source, args.mode)
        if state == "enabled" and args.cleanup_world:
            command = [sys.executable, str(Path(__file__).with_name("cleanWritingDrawings.py")),
                "--world-dir", args.cleanup_world, "--backup-dir", args.cleanup_backups]
            for name in ("jar", "java", "javac"):
                value = getattr(args, name)
                if value: command.extend(["--" + name, value])
            subprocess.run(command, check=True, pass_fds=(worker_fd,))
        print("ProjectWriting restart cleanup policy: " + state)
        return 0
    except (ValueError, OSError, UnicodeError, subprocess.SubprocessError) as error:
        print("ProjectWriting text-only configuration refused: " + str(error), file=sys.stderr)
        return 1

if __name__ == "__main__":
    sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "lib"))
    from shared_memory_budget import check_process
    check_process()
    sys.exit(main())
