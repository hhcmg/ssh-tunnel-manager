"""Release one SSH session's forwards when its Windows worker stops heartbeating.

Run through an SSH exec channel, with no PTY and no intermediate shell:
    exec python3 -u -c '<base64 loader>' TOKEN TTL_SECONDS
Only the verified, unprivileged parent sshd may receive SIGTERM. No remote files
are written and no process-group, cgroup, or port-based termination is used.
"""

import errno
import json
import math
import os
import re
import selectors
import signal
import sys
import time
from dataclasses import dataclass
from pathlib import Path


PREFIX = "TUNNEL_GUARD "
SSHD_NAMES = frozenset(("sshd", "sshd-session"))
TOKEN_PATTERN = re.compile(r"[A-Za-z0-9_-]{32,128}\Z")


class GuardError(Exception):
    """The watchdog cannot safely identify or supervise its SSH session."""


@dataclass(frozen=True)
class SessionIdentity:
    pid: int
    startticks: int
    uid: int
    comm: str
    bootid: str


def read_process_identity(pid, read_text=None):
    if read_text is None:
        read_text = lambda path: Path(path).read_text(encoding="ascii")
    stat = read_text("/proc/{}/stat".format(pid)).strip()
    opening, closing = stat.find("("), stat.rfind(")")
    if opening <= 0 or closing <= opening or int(stat[:opening].strip()) != pid:
        raise GuardError("Malformed parent process identity.")
    fields = stat[closing + 1:].split()
    if len(fields) <= 19 or fields[0] in ("Z", "X", "x"):
        raise GuardError("Parent sshd is no longer running.")
    comm = stat[opening + 1:closing]
    status = read_text("/proc/{}/status".format(pid))
    uid_lines = [line.split()[1:] for line in status.splitlines()
                 if line.startswith("Uid:")]
    if len(uid_lines) != 1 or len(uid_lines[0]) != 4:
        raise GuardError("Parent UID could not be verified.")
    uids = tuple(int(value) for value in uid_lines[0])
    if len(set(uids)) != 1 or uids[0] == 0:
        raise GuardError("Refusing a privileged or mixed-UID parent.")
    bootid = read_text("/proc/sys/kernel/random/boot_id").strip()
    if not re.fullmatch(r"[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}", bootid):
        raise GuardError("Kernel boot identity could not be verified.")
    return SessionIdentity(pid, int(fields[19]), uids[0], comm, bootid)


class SessionTarget:
    def __init__(self, identity, pidfd=None, read_identity=read_process_identity,
                 kill=os.kill, send_pidfd=None, close=os.close):
        self.identity = identity
        self.pidfd = pidfd
        self.read_identity = read_identity
        self.kill = kill
        self.send_pidfd = send_pidfd
        self.close_fd = close
        self.result = None

    def verify(self):
        current = self.read_identity(self.identity.pid)
        if current != self.identity or current.comm not in SSHD_NAMES:
            raise GuardError("Original sshd identity changed; no signal was sent.")

    def terminate(self):
        # Cleanup is idempotent even if EOF and a signal arrive together.
        if self.result is not None:
            return self.result
        try:
            self.verify()
            if self.pidfd is not None:
                self.send_pidfd(self.pidfd, signal.SIGTERM, None, 0)
            else:
                # Platforms without pidfd have an unavoidable narrow PID race;
                # re-read start time, all UIDs, comm, and boot ID immediately
                # before this single-PID signal, with no intervening I/O.
                self.verify()
                self.kill(self.identity.pid, signal.SIGTERM)
            self.result = "term-sent"
        except (FileNotFoundError, ProcessLookupError):
            self.result = "already-gone"
        except (OSError, ValueError, GuardError):
            self.result = "identity-unconfirmed-no-signal"
        return self.result

    def close(self):
        if self.pidfd is not None:
            self.close_fd(self.pidfd)
            self.pidfd = None


def capture_target(read_identity=read_process_identity, getppid=os.getppid,
                   getuid=None, geteuid=None, pidfd_open=None,
                   send_pidfd=None, kill=os.kill, close=os.close):
    if getuid is None:
        getuid = getattr(os, "getuid", lambda: -1)
    if geteuid is None:
        geteuid = getattr(os, "geteuid", lambda: -1)
    uid = getuid()
    if uid <= 0 or geteuid() != uid:
        raise GuardError("The watchdog requires an unprivileged user session.")
    parent = getppid()
    if parent <= 1:
        raise GuardError("No SSH session parent is present.")
    identity = read_identity(parent)
    if identity.uid != uid or identity.comm not in SSHD_NAMES:
        raise GuardError("Direct parent is not this user's sshd; use exec python3.")
    if pidfd_open is None:
        pidfd_open = getattr(os, "pidfd_open", None)
    if send_pidfd is None:
        send_pidfd = getattr(signal, "pidfd_send_signal", None)
    descriptor = None
    if pidfd_open is not None and send_pidfd is not None:
        try:
            descriptor = pidfd_open(parent, 0)
        except OSError as error:
            if error.errno not in (errno.ENOSYS, errno.EINVAL, errno.EPERM, errno.EACCES):
                raise GuardError("Could not retain the SSH session identity.") from error
    target = SessionTarget(identity, descriptor, read_identity, kill, send_pidfd, close)
    try:
        # Also detects parent exit/reparenting during the pidfd_open race.
        target.verify()
        if getppid() != parent:
            raise GuardError("SSH parent changed during watchdog initialization.")
    except Exception:
        target.close()
        raise
    return target


class HeartbeatReader:
    """Bound memory and accept only exact token lines, including Windows CRLF."""

    def __init__(self, token):
        self.expected = token.encode("ascii")
        self.pending = bytearray()
        self.dropping = False

    def feed(self, data):
        valid = False
        for byte in data:
            if byte == 10:
                if not self.dropping:
                    line = bytes(self.pending)
                    if line.endswith(b"\r"):
                        line = line[:-1]
                    valid = valid or line == self.expected
                self.pending.clear()
                self.dropping = False
            elif not self.dropping:
                self.pending.append(byte)
                if len(self.pending) > len(self.expected) + 1:
                    self.pending.clear()
                    self.dropping = True
        return valid


def emit(event, **fields):
    print(PREFIX + json.dumps(dict(event=event, **fields), separators=(",", ":")), flush=True)


def supervise(target, token, ttl, stop_reason, read=os.read, monotonic=time.monotonic,
              getppid=os.getppid, selector_factory=selectors.DefaultSelector,
              output=emit, guardpid=None):
    reader = HeartbeatReader(token)
    deadline = monotonic() + ttl
    with selector_factory() as selector:
        selector.register(0, selectors.EVENT_READ)
        identity = target.identity
        output("ready", token=token, guardpid=os.getpid() if guardpid is None else guardpid,
               sshdpid=identity.pid, startticks=identity.startticks, bootid=identity.bootid,
               cleanup_method="pidfd" if target.pidfd is not None else "verified-pid")
        while True:
            if stop_reason():
                return stop_reason()
            # Never retarget a new parent after the original sshd disappears.
            if getppid() != identity.pid:
                return "parent-changed"
            remaining = deadline - monotonic()
            if remaining <= 0:
                return "heartbeat-timeout"
            events = selector.select(min(remaining, 1.0))
            if monotonic() >= deadline:
                return "heartbeat-timeout"
            if not events:
                continue
            data = read(0, 4096)
            if not data:
                return "stdin-eof"
            if reader.feed(data):
                deadline = monotonic() + ttl


def main(argv=None):
    arguments = sys.argv[1:] if argv is None else argv
    if len(arguments) != 2 or not TOKEN_PATTERN.fullmatch(arguments[0]):
        emit("error", error="Expected a 32-128 character session token and TTL seconds.")
        return 2
    token = arguments[0]
    try:
        ttl = float(arguments[1])
        if not math.isfinite(ttl) or not 5 <= ttl <= 300:
            raise ValueError()
    except ValueError:
        emit("error", error="TTL must be between 5 and 300 seconds.")
        return 2
    requested_stop = [None]

    def on_signal(number, _frame):
        requested_stop[0] = "signal-{}".format(number)

    previous = {}
    target = None
    reason = "initialization-error"
    exit_code = 0
    try:
        for number in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT):
            previous[number] = signal.signal(number, on_signal)
        target = capture_target()
        reason = supervise(target, token, ttl, lambda: requested_stop[0])
    except (OSError, ValueError, GuardError) as error:
        emit("error", error=str(error))
        exit_code = 2
    finally:
        if target is not None:
            result = target.terminate()
            # Signal may close this SSH channel immediately, so cleanup precedes
            # reporting and reporting failures must not prevent FD cleanup.
            try:
                emit("stopping", reason=reason, cleanup=result)
            except (BrokenPipeError, OSError):
                pass
            finally:
                target.close()
            if result == "identity-unconfirmed-no-signal":
                exit_code = 3
        for number, handler in previous.items():
            signal.signal(number, handler)
    return exit_code


if __name__ == "__main__":
    raise SystemExit(main())
