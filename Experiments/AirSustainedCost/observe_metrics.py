"""Bounded, unprivileged macmon sidecar. No model or sampler is run on import.

The coordinator calls poll()/clock_if_due() on its existing one-second loop.
Only CPU-fake tests use the private command/limit injection points.
"""
from __future__ import annotations

import calendar
import copy
import ctypes
import datetime as dt
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import re
import selectors
import subprocess
import time


MACMON_SHA256 = "28f8d2b50b1a58e032295eb658de42088a49feb8affaf42803fb707edb0f73af"
SOURCE_COMMIT = "08653ddeb3c1206b6cc35d5a2bb442b4c64ad810"
NS = 1_000_000_000


def _sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def _utc_ns(text):
    """Parse the actual RFC3339 UTC/offset spelling without losing sub-us digits."""
    match = re.fullmatch(r"(\d{4}-\d\d-\d\d[Tt]\d\d:\d\d:\d\d)(?:\.(\d{1,9}))?([Zz]|[+-]\d\d:\d\d)", text or "")
    if not match:
        raise ValueError("timestamp is not RFC3339 with explicit zone")
    base, fraction, zone = match.groups()
    value = dt.datetime.fromisoformat(base.upper() + ("+00:00" if zone.upper() == "Z" else zone))
    return calendar.timegm(value.utctimetuple()) * NS + int((fraction or "0").ljust(9, "0"))


class _MachClock:
    def __init__(self):
        if platform.system() != "Darwin":
            raise RuntimeError("normal UTC/mach observation requires Darwin")
        library = ctypes.CDLL("/usr/lib/libSystem.B.dylib")

        class Timebase(ctypes.Structure):
            _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]

        info = Timebase()
        library.mach_timebase_info.argtypes = [ctypes.POINTER(Timebase)]
        library.mach_timebase_info.restype = ctypes.c_int
        if library.mach_timebase_info(ctypes.byref(info)) != 0 or not info.denom:
            raise RuntimeError("mach_timebase_info unavailable")
        library.mach_absolute_time.argtypes = []
        library.mach_absolute_time.restype = ctypes.c_uint64
        self.read = library.mach_absolute_time
        self.numer, self.denom = int(info.numer), int(info.denom)

    def anchor(self):
        before = time.monotonic_ns()
        mach_before = int(self.read())
        utc = time.time_ns()
        mach_after = int(self.read())
        after = time.monotonic_ns()
        return dict(monotonic_before_ns=before, mach_before_ticks=mach_before,
                    utc_epoch_ns=utc, mach_after_ticks=mach_after, monotonic_after_ns=after,
                    mach_before_ns=mach_before * self.numer // self.denom,
                    mach_after_ns=mach_after * self.numer // self.denom,
                    timebase_numer=self.numer, timebase_denom=self.denom,
                    read_order="monotonic_before,mach_before,UTC_time_ns,mach_after,monotonic_after")


class MetricsObserver:
    def __init__(self, config, attempt_dir, *, _test_command=None, _test_limits=None):
        self.config = dict(config)
        self.directory = Path(attempt_dir) / "metrics"
        self._test_command = list(_test_command) if _test_command is not None else None
        self.test_mode = self._test_command is not None
        self.limits = dict(sample_limit=3600, max_line_bytes=65536, max_stderr_bytes=2_097_152,
                           max_events=10000, wall_timeout_seconds=3600, anchor_interval_seconds=10)
        if _test_limits:
            if not self.test_mode:
                raise ValueError("test limits require the CPU-fake command")
            self.limits.update(_test_limits)
        self.process = None
        self._selector = selectors.DefaultSelector()
        self._files = {}
        self._pending = bytearray()
        self._started = self._stopped = self._stopping = False
        self._terminate_needed = False
        self._clock = None
        self._next_anchor_ns = None
        self._previous_source_ns = self._previous_receive_ns = None
        self._gap_warned = False
        self._meta = dict(format="odf-macmon-observer-v1", status="not_started", test_mode=self.test_mode,
                          first_error=None, sample_count=0, usable_sample_count=0, stdout_line_count=0,
                          stdout_bytes=0, stderr_bytes=0, event_count=0, anchor_count=0,
                          first_valid_receive_monotonic_ns=None, lead_anchor_receive_monotonic_ns=None,
                          last_valid_receive_monotonic_ns=None, observer_start=None, observer_stop=None,
                          native_start=None, native_end=None, sampler_pid=None, sampler_returncode=None,
                          eof_streams=[], termination=None, post_roll_satisfied=False,
                          limits=self.limits, scheduled_interval_ms=1000,
                          scope="Whole-SoC/host estimates. Not shader utilization, per-PID power, GPU active cycles or formal product energy acceptance.",
                          alignment="Use source UTC with UTC/mach anchors. Receive time diagnoses buffering only; polling delay is not added to alignment uncertainty.",
                          nominal_sample_scope="Approximately the one second preceding macmon UTC; not hardware-exact sample boundaries",
                          files={name: str(self.directory / name) for name in
                                 ("metadata.json", "samples.jsonl", "events.jsonl", "anchors.jsonl", "stdout.raw", "stderr.raw")})

    def _stamp(self):
        return dict(monotonic_ns=time.monotonic_ns(), utc_epoch_ns=time.time_ns())

    def _write_line(self, name, value):
        self._files[name].write(json.dumps(value, ensure_ascii=False, allow_nan=False) + "\n")

    def _event(self, kind, **fields):
        if "events.jsonl" not in self._files:
            return
        if self._meta["event_count"] >= self.limits["max_events"]:
            if self._meta["first_error"] is None:
                self._meta["first_error"] = dict(kind="event_limit", **self._stamp())
            self._terminate_needed = True
            return
        self._meta["event_count"] += 1
        event = dict(event_seq=self._meta["event_count"], kind=kind, **self._stamp())
        event.update(fields)
        self._write_line("events.jsonl", event)

    def _error(self, kind, message=""):
        if self._meta["first_error"] is None:
            self._meta["first_error"] = dict(kind=kind, message=str(message), **self._stamp(),
                                              native_started=self._meta["native_start"] is not None)
            try:
                self._event("first_error", error=self._meta["first_error"])
            except (OSError, ValueError):
                pass  # The in-memory first error still reaches the coordinator snapshot.
        self._meta["status"] = "failed"

    def _persist(self):
        if not self._started:
            return
        try:
            path = self.directory / ".metadata-next.json"
            path.write_text(json.dumps(self.snapshot(), ensure_ascii=False, indent=2, allow_nan=False) + "\n")
            path.replace(self.directory / "metadata.json")
        except (OSError, ValueError) as error:
            if self._meta["first_error"] is None:
                self._meta["first_error"] = dict(kind="metadata_write", message=str(error), **self._stamp())

    def start(self):
        if self._started or self._stopped:
            raise RuntimeError("observer instance cannot replay")
        self.directory.mkdir(parents=True, exist_ok=False)
        self._started = True
        for name in ("samples.jsonl", "events.jsonl", "anchors.jsonl"):
            self._files[name] = (self.directory / name).open("x", encoding="utf-8")
        for name in ("stdout.raw", "stderr.raw"):
            self._files[name] = (self.directory / name).open("xb")
        self._meta["observer_start"] = self._stamp()
        try:
            euid = os.geteuid()
            self._meta["user"] = dict(uid=os.getuid(), euid=euid, parent_pid=os.getpid())
            if not self.test_mode and (euid == 0 or self.config.get("expected_uid", euid) != euid):
                raise RuntimeError("normal sampler requires a matching non-root effective UID")
            binary = Path(self.config["binary_path"]).resolve(strict=True)
            actual_sha = _sha(binary)
            self._meta["sampler"] = dict(binary_path=str(binary), binary_sha256=actual_sha,
                                          expected_binary_sha256=MACMON_SHA256)
            if not self.test_mode and actual_sha != MACMON_SHA256:
                raise RuntimeError("fixed macmon v0.11.0 binary SHA mismatch")
            receipt_path = self.config.get("source_receipt_path")
            source = None
            if receipt_path:
                receipt = Path(receipt_path)
                receipt_sha = _sha(receipt)
                if self.config.get("source_receipt_sha256", receipt_sha) != receipt_sha:
                    raise RuntimeError("source receipt SHA mismatch")
                source = dict(path=str(receipt), sha256=receipt_sha, receipt=json.loads(receipt.read_text()))
            command = self._test_command or [str(binary), "pipe", "--samples", "0", "--soc-info", "--interval", "1000"]
            env = {key: value for key, value in os.environ.items() if not key.startswith("ANTHROPIC_")}
            env["MACMON_FORCE_CLPC"] = "1"
            self._meta["sampler"] = dict(binary_path=str(binary), binary_sha256=actual_sha,
                expected_binary_sha256=MACMON_SHA256, version="0.11.0" if not self.test_mode else "CPU-fake",
                source_commit=SOURCE_COMMIT, source_receipt=source, command=command,
                environment={"MACMON_FORCE_CLPC": "1"}, forced_clpc=True, legacy_fallback_enabled=False,
                normal_binary=self._test_command is None, provider_environment_removed=True)
            self._clock = _MachClock()
            info = time.get_clock_info("monotonic")
            self._meta["clock_info"] = dict(monotonic=dict(implementation=info.implementation, monotonic=info.monotonic,
                adjustable=info.adjustable, resolution_seconds=info.resolution),
                parent_receive_unit="time.monotonic_ns nanoseconds", mach_api="mach_absolute_time (ctypes libSystem)",
                mach_raw_unit="ticks", timebase_numer=self._clock.numer, timebase_denom=self._clock.denom,
                mach_converted_unit="nanoseconds = ticks * numer / denom; no opaque DispatchTime.rawValue",
                utc_unit="Unix epoch nanoseconds", anchor_order="monotonic_before,mach_before,UTC,mach_after,monotonic_after")
            self.clock_if_due(force=True)
            self.process = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                             stderr=subprocess.PIPE, env=env, bufsize=0)
            self._meta["sampler_pid"] = self.process.pid
            self._meta["popen_return"] = self._stamp()
            for stream, name in ((self.process.stdout, "stdout"), (self.process.stderr, "stderr")):
                os.set_blocking(stream.fileno(), False)
                self._selector.register(stream, selectors.EVENT_READ, name)
            self._meta["status"] = "running"
            self._event("sampler_started", pid=self.process.pid)
            self._persist()
            return self.snapshot()
        except Exception as error:
            self._error("start_failed", str(error))
            self._persist()
            self.close()
            raise

    def clock_if_due(self, *, force=False):
        if self._clock is None or self._stopped:
            return None
        stamp = time.monotonic_ns()
        if not force and self._next_anchor_ns is not None and stamp < self._next_anchor_ns:
            return None
        anchor = self._clock.anchor()
        self._meta["anchor_count"] += 1
        anchor.update(format="odf-utc-mach-anchor-v1", anchor_seq=self._meta["anchor_count"])
        self._write_line("anchors.jsonl", anchor)
        if self._next_anchor_ns is None:
            self._next_anchor_ns = stamp + int(self.limits["anchor_interval_seconds"] * NS)
        else:
            interval = int(self.limits["anchor_interval_seconds"] * NS)
            while self._next_anchor_ns <= stamp:
                self._next_anchor_ns += interval
        self._files["anchors.jsonl"].flush()
        return anchor

    def _stdout_line(self, raw):
        receive = time.monotonic_ns()
        receive_utc = time.time_ns()
        self._meta["stdout_line_count"] += 1
        envelope = dict(format="odf-macmon-sample-v1", line_seq=self._meta["stdout_line_count"], sample_seq=None,
            record_kind="invalid", raw_line=raw.decode("utf-8", errors="replace"), payload=None,
            utc_sample_raw=None, utc_epoch_ns=None, receive_monotonic_ns=receive,
            receive_utc_ns=receive_utc, discard=False, valid_for_timing=False, nominal_interval_ns=NS,
            delta_source_utc_ns=None, delta_receive_monotonic_ns=None)
        try:
            text = raw.decode("utf-8")
            payload = json.loads(text, parse_constant=lambda x: (_ for _ in ()).throw(ValueError(f"non-JSON {x}")))
            if not isinstance(payload, dict):
                raise ValueError("sample must be a JSON object")
            json.dumps(payload, allow_nan=False)
            envelope["payload"] = payload
            envelope["utc_sample_raw"] = payload.get("timestamp")
            source_ns = _utc_ns(payload.get("timestamp"))
            for key in ("gpu_freq_mhz", "gpu_active_ratio"):
                value = payload.get(key)
                if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
                    raise ValueError(f"missing/invalid core observation {key}")
            self._meta["sample_count"] += 1
            index = self._meta["sample_count"]
            envelope.update(record_kind="sample", sample_seq=index, utc_epoch_ns=source_ns,
                            discard=index == 1, valid_for_timing=True)
            if self._previous_source_ns is not None:
                delta = source_ns - self._previous_source_ns
                envelope["delta_source_utc_ns"] = delta
                envelope["delta_receive_monotonic_ns"] = receive - self._previous_receive_ns
                if delta > 1_500_000_000 or delta <= 0:
                    self._event("sample_gap" if delta > 0 else "source_time_nonincreasing",
                                previous_utc_epoch_ns=self._previous_source_ns, source_utc_epoch_ns=source_ns,
                                delta_source_utc_ns=delta, sample_seq=index)
            self._previous_source_ns, self._previous_receive_ns = source_ns, receive
            if self._meta["first_valid_receive_monotonic_ns"] is None:
                self._meta["first_valid_receive_monotonic_ns"] = receive
            self._meta["last_valid_receive_monotonic_ns"] = receive
            if index > 1:
                self._meta["usable_sample_count"] += 1
                if self._meta["lead_anchor_receive_monotonic_ns"] is None:
                    self._meta["lead_anchor_receive_monotonic_ns"] = receive
            self._gap_warned = False
        except (ValueError, TypeError, UnicodeError, OverflowError) as error:
            envelope["record_kind"] = "invalid_sample"
            envelope["valid_for_timing"] = False
            envelope["parse_error"] = str(error)
            self._error("invalid_sample", str(error))
        self._write_line("samples.jsonl", envelope)
        if self._meta["sample_count"] >= self.limits["sample_limit"]:
            self._error("sample_limit", "bounded sample count reached")
            self._terminate_needed = True

    def _read(self, key):
        stream, name = key.fileobj, key.data
        for _ in range(32):  # Bounded per poll; no busy polling thread.
            try:
                chunk = os.read(stream.fileno(), 65536)
            except BlockingIOError:
                return
            if not chunk:
                self._selector.unregister(stream)
                self._meta["eof_streams"].append(name)
                self._event("stream_eof", stream=name)
                if name == "stdout" and not self._stopping:
                    self._error("unexpected_stdout_eof")
                return
            self._files[name + ".raw"].write(chunk)
            self._meta[name + "_bytes"] += len(chunk)
            if name == "stderr":
                self._event("stderr_chunk", bytes=len(chunk), text=chunk.decode("utf-8", errors="replace"))
                if self._meta["stderr_bytes"] > self.limits["max_stderr_bytes"]:
                    self._error("stderr_limit"); self._terminate_needed = True
                continue
            if self._meta["sample_count"] >= self.limits["sample_limit"]:
                # Preserve any already-buffered raw bytes after the limit; do not
                # turn late pipe data into more counted/usable samples.
                self._terminate_needed = True
                return
            self._pending.extend(chunk)
            while b"\n" in self._pending:
                line, _, tail = self._pending.partition(b"\n")
                self._pending = bytearray(tail)
                if len(line) + 1 > self.limits["max_line_bytes"]:
                    self._error("line_limit"); self._terminate_needed = True
                    self._pending.clear(); return
                self._stdout_line(bytes(line) + b"\n")
                if self._terminate_needed:
                    self._pending.clear(); return
            if len(self._pending) > self.limits["max_line_bytes"]:
                self._error("line_limit"); self._terminate_needed = True
                self._pending.clear(); return

    def poll(self):
        if not self._started or self._stopped:
            return self.snapshot()
        try:
            for key, _ in self._selector.select(timeout=0):
                self._read(key)
            if self.process is not None:
                code = self.process.poll()
                if code is not None:
                    self._meta["sampler_returncode"] = code
                    if not self._stopping:
                        self._error("unexpected_sampler_exit", str(code))
                start = self._meta.get("popen_return", self._meta["observer_start"])["monotonic_ns"]
                if time.monotonic_ns() - start > self.limits["wall_timeout_seconds"] * NS:
                    self._error("observer_wall_timeout"); self._terminate_needed = True
            last = self._meta["last_valid_receive_monotonic_ns"]
            if last is not None and time.monotonic_ns() - last > 2_500_000_000 and not self._gap_warned:
                self._event("receive_gap", last_valid_receive_monotonic_ns=last)
                self._gap_warned = True
            if self._terminate_needed:
                self._request_termination("observer_bound")
            for file in self._files.values():
                file.flush()
        except Exception as error:
            self._error("poll_failed", str(error))
        return self.snapshot()

    def ready_for_native(self, minimum_lead_seconds=10):
        if not self.test_mode and minimum_lead_seconds < 10:
            raise ValueError("normal observation requires at least10 seconds lead")
        lead = self._meta["lead_anchor_receive_monotonic_ns"]
        last = self._meta["last_valid_receive_monotonic_ns"]
        stamp = time.monotonic_ns()
        return bool(self._started and not self._stopped and not self._stopping and
                    self._meta["first_error"] is None and self.process is not None and self.process.poll() is None and
                    lead is not None and last is not None and stamp - lead >= minimum_lead_seconds * NS and
                    stamp - last <= 2_500_000_000)

    def mark_native_started(self, pid=None):
        if self._meta["native_start"] is not None:
            raise RuntimeError("native start already marked")
        self._meta["native_start"] = dict(**self._stamp(), pid=pid)
        self._event("native_started", native=self._meta["native_start"])
        self.clock_if_due(force=True); self._persist()
        return self.snapshot()

    def mark_native_finished(self, returncode=None):
        if self._meta["native_start"] is None or self._meta["native_end"] is not None:
            raise RuntimeError("native finish requires exactly one prior native start")
        self._meta["native_end"] = dict(**self._stamp(), returncode=returncode)
        self._event("native_finished", native=self._meta["native_end"])
        self.clock_if_due(force=True); self._persist()
        return self.snapshot()

    def _request_termination(self, reason):
        self._stopping = True
        if self.process is not None and self.process.poll() is None:
            if self._meta["termination"] is None:
                self._meta["termination"] = dict(reason=reason, pid=self.process.pid, signal="SIGTERM", **self._stamp())
                self._event("sampler_termination_requested", termination=self._meta["termination"])
                self.process.terminate()

    def stop_after_native(self, post_seconds=10):
        if self._stopped:
            return self.snapshot()
        if not self.test_mode and post_seconds < 10:
            raise ValueError("normal observation requires at least10 seconds post-roll")
        end = self._meta["native_end"]
        if end is None:
            return self.abort("native_end_not_marked")
        deadline = end["monotonic_ns"] + int(post_seconds * NS)
        while time.monotonic_ns() < deadline:
            self.poll(); self.clock_if_due()
            time.sleep(min(1.0, max(0, (deadline-time.monotonic_ns())/NS)))
        self.poll(); self.clock_if_due(force=True)
        self._meta["post_roll_satisfied"] = bool(self.process is not None and self.process.poll() is None and
                                                   self._meta["first_error"] is None and not self._stopping)
        return self._close("normal_post_roll_complete")

    def abort(self, reason):
        if self._stopped:
            return self.snapshot()
        self._event("observer_aborted", reason=str(reason))
        self._meta["abort_reason"] = str(reason)
        return self._close("abort:" + str(reason))

    def close(self):
        return self._close("close")

    def _close(self, reason):
        if self._stopped:
            return self.snapshot()
        if not self._started:
            self._stopped = True
            return self.snapshot()
        self._request_termination(reason)
        if self.process is not None:
            try:
                self.process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                self._event("sampler_owned_pid_kill", pid=self.process.pid)
                self.process.kill(); self.process.wait(timeout=2)
            self.poll()
            self._meta["sampler_returncode"] = self.process.returncode
        if self._pending:
            self._event("unterminated_stdout_tail", bytes=len(self._pending), raw_tail=self._pending.decode("utf-8", errors="replace"))
            self._error("unterminated_stdout_tail")
            self._pending.clear()
        self.clock_if_due(force=True)
        self._meta["observer_stop"] = dict(reason=reason, **self._stamp())
        self._meta["status"] = "failed" if self._meta["first_error"] is not None else "stopped"
        self._stopped = True
        self._persist()
        self._selector.close()
        for file in self._files.values():
            file.flush(); file.close()
        if self.process is not None:
            self.process.stdout.close(); self.process.stderr.close()
        return self.snapshot()

    def snapshot(self):
        # Metadata only: sample payloads remain in the append-only raw files.
        return copy.deepcopy(self._meta)
