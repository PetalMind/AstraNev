#!/usr/bin/env python3
"""Serialize direct Xcode/Swift invocations and await their compiler children."""

import fcntl
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

LOCK_PATH = "/tmp/codex-global-build.lock"
COMPILERS = {
    "xcodebuild", "swift", "swiftc", "swift-driver", "swift-frontend",
    "clang", "clang++", "cc", "c++", "gcc", "g++", "cc1", "cc1plus",
    "rustc", "cargo", "javac", "kotlinc", "ninja", "make",
    "ld", "ld-prime", "metal", "metallib", "actool", "ibtool", "dsymutil",
}
cancelled = False


def request_cancellation(_signum, _frame):
    # Do not raise inside Popen: it must return the child's process-group ID.
    global cancelled
    cancelled = True


def read_process_snapshot():
    commands = {}
    for line in subprocess.check_output(["ps", "-axo", "pid=,command="], text=True).splitlines():
        fields = line.strip().split(None, 1)
        if len(fields) == 2:
            commands[int(fields[0])] = fields[1]
    output = subprocess.check_output(
        ["ps", "-axo", "pid=,ppid=,pgid=,state=,lstart=,comm="], text=True
    )
    result = {}
    for line in output.splitlines():
        fields = line.strip().split(None, 9)
        if len(fields) != 10 or fields[3].startswith("Z"):
            continue
        pid = int(fields[0])
        result[pid] = {
            "parent": int(fields[1]), "group": int(fields[2]),
            "birth": " ".join(fields[4:9]),
            # comm is separate from argv; Xcode paths may contain spaces.
            "name": Path(fields[9]).name, "command": commands.get(pid, ""),
        }
    return result


def process_snapshot():
    reported = False
    while True:
        try:
            return read_process_snapshot()
        except (OSError, ValueError, subprocess.CalledProcessError):
            # A failed observation is not proof that compilers have finished.
            if not reported:
                print("Nie można odczytać procesów. Zachowuję blokadę i ponawiam odczyt.", flush=True)
                reported = True
            time.sleep(2)


def is_compiler(process):
    name, command = process["name"], process["command"]
    if name in COMPILERS:
        return True
    if name == "cmake":
        return "--build" in command
    if name in ("go", "dotnet"):
        return any(f" {action} " in command + " " for action in ("build", "test", "install", "publish", "pack"))
    if name in ("dart", "dartaotruntime"):
        return any(marker in command for marker in (" compile ", "frontend_server", "kernel_worker"))
    return False


def compilation_ids(snapshot):
    return sorted((pid, process["name"]) for pid, process in snapshot.items() if is_compiler(process))


def observe_owned(snapshot, group, owned):
    # Remember descendants that create their own process group (swift-driver
    # does this), and keep their identities after their parent has exited.
    owned = {pid: birth for pid, birth in owned.items()
             if pid in snapshot and snapshot[pid]["birth"] == birth}
    for pid, process in snapshot.items():
        if process["group"] == group:
            owned[pid] = process["birth"]
    changed = True
    while changed:
        changed = False
        for pid, process in snapshot.items():
            if process["parent"] in owned and pid not in owned:
                owned[pid] = process["birth"]
                changed = True
    return owned


def main():
    command = sys.argv[1:]
    if command[:1] == ["--"]:
        command = command[1:]
    if not command:
        raise SystemExit("Użycie: with-global-build-lock.py -- polecenie [argumenty]")
    driver = Path(command[0]).name
    if driver == "xcrun" and len(command) > 1:
        driver = command[1]
    if driver not in ("xcodebuild", "swiftc", "swift-frontend"):
        raise SystemExit("Uruchom bezpośrednio xcodebuild lub swiftc, bez skryptu tworzącego procesy w tle.")
    signal.signal(signal.SIGTERM, request_cancellation)
    signal.signal(signal.SIGINT, request_cancellation)

    # Never unlink, replace or truncate the shared lock file.
    with open(LOCK_PATH, "a") as lock:
        print(f"Oczekiwanie na globalną blokadę: {LOCK_PATH}", flush=True)
        while not cancelled:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                time.sleep(2)
        if cancelled:
            return 130
        print("Uzyskano globalną blokadę kompilacji.", flush=True)
        previous = None
        while active := compilation_ids(process_snapshot()):
            if cancelled:
                return 130  # This invocation has not started any child yet.
            if active != previous:
                print(f"Oczekiwanie na wcześniejsze kompilacje: {active}", flush=True)
                previous = active
            time.sleep(2)
        if cancelled:
            return 130

        process = subprocess.Popen(command, start_new_session=True, pass_fds=(lock.fileno(),))
        owned = {}
        signalled = set()
        status = None
        try:
            while True:
                snapshot = process_snapshot()
                owned = observe_owned(snapshot, process.pid, owned)
                status = process.poll()
                active = compilation_ids(snapshot)
                if cancelled:
                    # Only observed children of this invocation are signalled.
                    for pid, birth in owned.items():
                        identity = (pid, birth)
                        if identity not in signalled:
                            try:
                                os.kill(pid, signal.SIGTERM)
                            except ProcessLookupError:
                                pass
                            signalled.add(identity)
                if status is not None and not owned and not active:
                    break
                time.sleep(2)
        finally:
            # On an unexpected Python error, retain the lock until the command,
            # its observed descendants and any service-owned compilers finish.
            while True:
                snapshot = process_snapshot()
                owned = observe_owned(snapshot, process.pid, owned)
                if process.poll() is not None and not owned and not compilation_ids(snapshot):
                    break
                time.sleep(2)
        status = 130 if cancelled else status
        print(f"Kompilacja zakończona, kod: {status}. Zwalniam blokadę.", flush=True)
        return status


if __name__ == "__main__":
    sys.exit(main())
