"""Offline watchdog tests: no SSH, real /proc reads, or process signals."""

import errno
import signal
import unittest
from unittest import mock

import tunnel_guard as guard


TOKEN = "0123456789abcdef" * 4
BOOT = "11111111-2222-3333-4444-555555555555"
IDENTITY = guard.SessionIdentity(701, 123456, 1013, "sshd", BOOT)


class FakeInput:
    def __init__(self, schedule):
        self.now = 0.0
        self.schedule = [list(item) for item in schedule]
        self.pending = None

    def __enter__(self):
        return self

    def __exit__(self, *_args):
        return False

    def register(self, fd, events):
        assert fd == 0 and events == guard.selectors.EVENT_READ

    def select(self, timeout):
        if not self.schedule or self.schedule[0][0] > timeout:
            self.now += timeout
            if self.schedule:
                self.schedule[0][0] -= timeout
            return []
        delay, self.pending = self.schedule.pop(0)
        self.now += delay
        return [(object(), guard.selectors.EVENT_READ)]

    def read(self, fd, count):
        assert fd == 0 and count == 4096
        data, self.pending = self.pending, None
        return data


class GuardTests(unittest.TestCase):
    def setUp(self):
        self.signals = []
        self.closed = []

    def target(self, identity=IDENTITY, read_identity=None, pidfd=88):
        return guard.SessionTarget(
            identity, pidfd, read_identity or (lambda _pid: identity),
            kill=lambda pid, sig: self.signals.append(("pid", pid, sig)),
            send_pidfd=lambda fd, sig, info, flags: self.signals.append(("pidfd", fd, sig)),
            close=self.closed.append,
        )

    def supervise(self, schedule, stop_reason=lambda: None, getppid=lambda: 701):
        source = FakeInput(schedule)
        output = []
        result = guard.supervise(
            self.target(), TOKEN, 5, stop_reason, read=source.read,
            monotonic=lambda: source.now, getppid=getppid,
            selector_factory=lambda: source,
            output=lambda event, **fields: output.append((event, fields)), guardpid=702,
        )
        return result, source.now, output

    def test_proc_stat_uid_and_boot_identity(self):
        # fields[19] after ')' is /proc/stat field 22 (starttime).
        stat = "701 (sshd) " + " ".join(["S", "700"] + ["0"] * 17 + ["123456"])
        files = {"/proc/701/stat": stat, "/proc/701/status": "Uid:\t1013\t1013\t1013\t1013\n",
                 "/proc/sys/kernel/random/boot_id": BOOT}
        self.assertEqual(IDENTITY, guard.read_process_identity(701, files.__getitem__))
        for uids in ("0 0 0 0", "1013 0 1013 1013"):
            files["/proc/701/status"] = "Uid: " + uids
            with self.assertRaises(guard.GuardError):
                guard.read_process_identity(701, files.__getitem__)

    def test_capture_pidfd_revalidates_and_only_signals_original(self):
        target = guard.capture_target(
            read_identity=lambda _pid: IDENTITY, getppid=lambda: 701,
            getuid=lambda: 1013, geteuid=lambda: 1013,
            pidfd_open=lambda pid, flags: 88,
            send_pidfd=lambda fd, sig, info, flags: self.signals.append(("pidfd", fd, sig)),
            kill=lambda *_args: self.fail("PID fallback used despite pidfd"), close=self.closed.append,
        )
        self.assertEqual("term-sent", target.terminate())
        self.assertEqual("term-sent", target.terminate())
        self.assertEqual([("pidfd", 88, signal.SIGTERM)], self.signals)
        target.close()
        self.assertEqual([88], self.closed)

    def test_capture_rejects_shell_root_and_different_uid(self):
        for identity in (
            guard.SessionIdentity(701, 123456, 1013, "bash", BOOT),
            guard.SessionIdentity(701, 123456, 0, "sshd", BOOT),
            guard.SessionIdentity(701, 123456, 1014, "sshd", BOOT),
        ):
            with self.assertRaises(guard.GuardError):
                guard.capture_target(read_identity=lambda _pid: identity, getppid=lambda: 701,
                                     getuid=lambda: 1013, geteuid=lambda: 1013,
                                     pidfd_open=lambda *_args: self.fail("Unsafe parent acquired"))
        with self.assertRaises(guard.GuardError):
            guard.capture_target(getuid=lambda: 0, geteuid=lambda: 0)

    def test_capture_reparent_and_pid_reuse_close_handle_without_signal(self):
        for changed_identity, parents in (
            (guard.SessionIdentity(701, 999999, 1013, "sshd", BOOT), [701, 701]),
            (IDENTITY, [701, 1]),
        ):
            reads = iter([IDENTITY, changed_identity])
            parent = iter(parents)
            with self.assertRaises(guard.GuardError):
                guard.capture_target(read_identity=lambda _pid: next(reads), getppid=lambda: next(parent),
                                     getuid=lambda: 1013, geteuid=lambda: 1013,
                                     pidfd_open=lambda *_args: 88, send_pidfd=lambda *_args: self.fail("signal"),
                                     close=self.closed.append)
        self.assertEqual([88, 88], self.closed)

    def test_pidfd_unavailable_fallback_revalidates_before_single_term(self):
        def unavailable(*_args):
            raise OSError(errno.ENOSYS, "unsupported")
        reads = mock.Mock(return_value=IDENTITY)
        target = guard.capture_target(
            read_identity=reads, getppid=lambda: 701, getuid=lambda: 1013, geteuid=lambda: 1013,
            pidfd_open=unavailable, send_pidfd=lambda *_args: self.fail("pidfd unexpectedly used"),
            kill=lambda pid, sig: self.signals.append(("pid", pid, sig)), close=self.closed.append,
        )
        self.assertEqual("term-sent", target.terminate())
        self.assertEqual(4, reads.call_count)
        self.assertEqual([("pid", 701, signal.SIGTERM)], self.signals)

    def test_changed_start_uid_comm_or_boot_prevents_all_signals(self):
        for identity in (
            guard.SessionIdentity(701, 123457, 1013, "sshd", BOOT),
            guard.SessionIdentity(701, 123456, 1014, "sshd", BOOT),
            guard.SessionIdentity(701, 123456, 1013, "bash", BOOT),
            guard.SessionIdentity(701, 123456, 1013, "sshd", "different-boot"),
        ):
            target = self.target(read_identity=lambda _pid: identity)
            self.assertEqual("identity-unconfirmed-no-signal", target.terminate())
        self.assertEqual([], self.signals)

    def test_missing_parent_is_not_replaced_or_signalled(self):
        def gone(_pid):
            raise FileNotFoundError()
        self.assertEqual("already-gone", self.target(read_identity=gone).terminate())
        self.assertEqual([], self.signals)

    def test_heartbeat_accepts_partial_token_and_windows_crlf(self):
        reader = guard.HeartbeatReader(TOKEN)
        self.assertFalse(reader.feed(TOKEN[:20].encode()))
        self.assertTrue(reader.feed(TOKEN[20:].encode() + b"\r\n"))
        self.assertTrue(reader.feed(TOKEN.encode() + b"\n"))

    def test_wrong_or_oversized_lines_never_renew_and_memory_is_bounded(self):
        reader = guard.HeartbeatReader(TOKEN)
        for data in (b"x" * 100000, b"\n", b" " + TOKEN.encode() + b"\n",
                     TOKEN.encode() + b"suffix\n", TOKEN.encode() + b"\r\r\n"):
            self.assertFalse(reader.feed(data))
            self.assertLessEqual(len(reader.pending), len(TOKEN) + 1)
        self.assertTrue(reader.feed(TOKEN.encode() + b"\n"))

    def test_ready_contains_expected_session_identity(self):
        result, _now, output = self.supervise([(0, b"")])
        self.assertEqual("stdin-eof", result)
        self.assertEqual(("ready", dict(token=TOKEN, guardpid=702, sshdpid=701,
                                        startticks=123456, bootid=BOOT, cleanup_method="pidfd")), output[0])

    def test_ready_reports_verified_pid_fallback(self):
        source = FakeInput([(0, b"")])
        output = []
        guard.supervise(self.target(pidfd=None), TOKEN, 5, lambda: None,
                        read=source.read, monotonic=lambda: source.now,
                        getppid=lambda: 701, selector_factory=lambda: source,
                        output=lambda event, **fields: output.append((event, fields)), guardpid=702)
        self.assertEqual("verified-pid", output[0][1]["cleanup_method"])

    def test_valid_heartbeat_extends_deadline_until_eof(self):
        result, now, _output = self.supervise([(2, TOKEN.encode() + b"\n"), (4, b"")])
        self.assertEqual("stdin-eof", result)
        self.assertEqual(6, now)

    def test_silent_or_invalid_input_times_out(self):
        for schedule in ([], [(1, b"wrong\n")] * 10):
            result, now, _output = self.supervise(schedule)
            self.assertEqual("heartbeat-timeout", result)
            self.assertEqual(5, now)

    def test_late_heartbeat_does_not_resurrect_expired_lease(self):
        result, now, _output = self.supervise([(5, TOKEN.encode() + b"\n")])
        self.assertEqual("heartbeat-timeout", result)
        self.assertEqual(5, now)

    def test_reparent_and_signal_request_end_supervision(self):
        result, _now, _output = self.supervise([], getppid=lambda: 1)
        self.assertEqual("parent-changed", result)
        result, _now, _output = self.supervise([], stop_reason=lambda: "signal-15")
        self.assertEqual("signal-15", result)

    def test_invalid_arguments_do_not_capture_or_signal_any_process(self):
        with mock.patch.object(guard, "emit"), mock.patch.object(guard, "capture_target") as capture:
            for arguments in ([], ["short", "30"], [TOKEN, "nan"], [TOKEN, "4"], [TOKEN, "301"]):
                self.assertEqual(2, guard.main(arguments))
            capture.assert_not_called()

    def test_main_cleans_verified_target_on_eof_timeout_and_signal(self):
        for reason in ("stdin-eof", "heartbeat-timeout", "signal-15", "parent-changed"):
            target = mock.Mock()
            target.terminate.return_value = "term-sent"
            with mock.patch.object(guard.signal, "SIGHUP", 1, create=True), \
                    mock.patch.object(guard.signal, "signal", return_value=None), \
                    mock.patch.object(guard, "capture_target", return_value=target), \
                    mock.patch.object(guard, "supervise", return_value=reason), \
                    mock.patch.object(guard, "emit") as output:
                self.assertEqual(0, guard.main([TOKEN, "30"]))
                target.terminate.assert_called_once_with()
                target.close.assert_called_once_with()
                output.assert_called_with("stopping", reason=reason, cleanup="term-sent")

    def test_main_io_failure_still_cleans_verified_target(self):
        target = mock.Mock()
        target.terminate.return_value = "term-sent"
        with mock.patch.object(guard.signal, "SIGHUP", 1, create=True), \
                mock.patch.object(guard.signal, "signal", return_value=None), \
                mock.patch.object(guard, "capture_target", return_value=target), \
                mock.patch.object(guard, "supervise", side_effect=OSError("stdin is unavailable")), \
                mock.patch.object(guard, "emit"):
            self.assertEqual(2, guard.main([TOKEN, "30"]))
            target.terminate.assert_called_once_with()
            target.close.assert_called_once_with()

    def test_failed_parent_verification_never_enters_supervision(self):
        with mock.patch.object(guard.signal, "SIGHUP", 1, create=True), \
                mock.patch.object(guard.signal, "signal", return_value=None), \
                mock.patch.object(guard, "capture_target", side_effect=guard.GuardError("wrong parent")), \
                mock.patch.object(guard, "supervise") as supervise, \
                mock.patch.object(guard, "emit"):
            self.assertEqual(2, guard.main([TOKEN, "30"]))
            supervise.assert_not_called()

    def test_signal_handler_requests_cleanup_without_sending_from_handler(self):
        target = mock.Mock()
        target.terminate.return_value = "term-sent"
        handlers = {}

        def remember(number, handler):
            handlers[number] = handler
            return None

        def receive_signal(_target, _token, _ttl, stop_reason):
            handlers[signal.SIGTERM](signal.SIGTERM, None)
            target.terminate.assert_not_called()
            return stop_reason()

        with mock.patch.object(guard.signal, "SIGHUP", 1, create=True), \
                mock.patch.object(guard.signal, "signal", side_effect=remember), \
                mock.patch.object(guard, "capture_target", return_value=target), \
                mock.patch.object(guard, "supervise", side_effect=receive_signal), \
                mock.patch.object(guard, "emit"):
            self.assertEqual(0, guard.main([TOKEN, "30"]))
            target.terminate.assert_called_once_with()


if __name__ == "__main__":
    unittest.main()
