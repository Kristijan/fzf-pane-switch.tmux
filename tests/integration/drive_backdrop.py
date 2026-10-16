#!/usr/bin/env python3
"""Exercise floating-pane backdrop state through an attached tmux client."""

import os
import pty
import select
import signal
import subprocess
import sys
import time


def run_tmux(tmux_binary, socket_name, *arguments, check=True):
    return subprocess.run(
        [tmux_binary, "-L", socket_name, *arguments],
        check=check,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    ).stdout


def read_available(fd, transcript):
    while select.select([fd], [], [], 0)[0]:
        try:
            chunk = os.read(fd, 65536)
        except OSError:
            return
        if not chunk:
            return
        transcript.extend(chunk)


def wait_for(predicate, fd, transcript, timeout=15):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        read_available(fd, transcript)
        result = predicate()
        if result:
            return result
        time.sleep(0.05)
    return None


def pane_rows(tmux_binary, socket_name):
    output = run_tmux(
        tmux_binary,
        socket_name,
        "list-panes",
        "-t",
        "integration:0",
        "-F",
        "#{pane_id} #{pane_floating_flag} #{@fzf_pane_switch_backdrop}",
    )
    return [line.split(" ", 2) for line in output.splitlines()]


def floating_pane(tmux_binary, socket_name):
    for pane_id, floating, marker in pane_rows(tmux_binary, socket_name):
        if floating == "1" and marker == "1":
            return pane_id
    return None


def main():
    if len(sys.argv) not in (3, 5, 6):
        print(
            "usage: drive_backdrop.py TMUX SOCKET "
            "[EXPECTED_BASE EXPECTED_LOCAL [EXTERNAL_STYLE]]",
            file=sys.stderr,
        )
        return 2

    tmux_binary, socket_name = sys.argv[1:3]
    expected_base = sys.argv[3] if len(sys.argv) >= 5 else "fg=cyan"
    expected_local = sys.argv[4] if len(sys.argv) >= 5 else ""
    external_style = sys.argv[5] if len(sys.argv) == 6 else ""
    expected_preview_token = os.environ.get("EXPECTED_PREVIEW_TOKEN", "")
    scenario = os.environ.get("BACKDROP_SCENARIO", "")
    observer_pid = None
    observer_fd = None
    transcript = bytearray()
    child_pid, fd = pty.fork()
    if child_pid == 0:
        environment = os.environ.copy()
        environment["TERM"] = "xterm-256color"
        os.execve(
            tmux_binary,
            [tmux_binary, "-L", socket_name, "attach-session", "-t", "integration:0"],
            environment,
        )

    try:
        time.sleep(0.4)
        read_available(fd, transcript)
        os.write(fd, b"\x02s\x02s" if scenario == "double-launch" else b"\x02s")

        if scenario in ("signal-setup", "style-setup"):
            marker = os.environ["BACKDROP_SIGNAL_MARKER"]
            interrupted = wait_for(lambda: os.path.isfile(marker), fd, transcript)
            if not interrupted:
                raise RuntimeError("setup interruption was not exercised")
            def cleaned():
                options = run_tmux(tmux_binary, socket_name, "show-options", "-w", "-t", "integration:0")
                hooks = run_tmux(tmux_binary, socket_name, "show-hooks", "-w", "-t", "integration:0")
                expected_style = "window-style fg=green\n" if scenario == "style-setup" else ""
                return "backdrop-" not in options and options == expected_style and "fzf-pane-switch" not in hooks
            if not wait_for(cleaned, fd, transcript):
                raise RuntimeError("interrupted setup left backdrop state or overwrote the external style")
            return 0

        floating = wait_for(
            lambda: floating_pane(tmux_binary, socket_name), fd, transcript
        )
        if not floating:
            raise RuntimeError("switcher did not create and mark a floating pane")

        origin_client = ""
        if scenario == "multi-client":
            origin_client = run_tmux(tmux_binary, socket_name, "list-clients", "-F", "#{client_name}").strip()
            observer_pid, observer_fd = pty.fork()
            if observer_pid == 0:
                environment = os.environ.copy()
                environment["TERM"] = "xterm-256color"
                os.execve(tmux_binary, [tmux_binary, "-L", socket_name, "attach-session", "-t", "observer"], environment)
            if not wait_for(lambda: len(run_tmux(tmux_binary, socket_name, "list-clients").splitlines()) == 2, fd, transcript):
                raise RuntimeError("observer client did not attach")

        if scenario == "double-launch":
            time.sleep(0.15)
            marked = [row for row in pane_rows(tmux_binary, socket_name) if row[1:] == ["1", "1"]]
            hooks = run_tmux(tmux_binary, socket_name, "show-hooks", "-w", "-t", "integration:0")
            if len(marked) != 1 or hooks.count("fzf-pane-switch-") != 1:
                raise RuntimeError(f"duplicate launch corrupted state: {marked!r}; {hooks!r}")

        if expected_preview_token:
            # Inspect the floating pane's actual screen grid. Counting terminal
            # bytes can miss a valid preview when tmux sends incremental redraws.
            preview_rendered = wait_for(
                lambda: expected_preview_token in run_tmux(
                    tmux_binary, socket_name, "capture-pane", "-p", "-t", floating
                ),
                fd, transcript, timeout=10,
            )
            if not preview_rendered:
                origin = next(
                    pane_id
                    for pane_id, is_floating, _ in pane_rows(
                        tmux_binary, socket_name
                    )
                    if is_floating == "0"
                )
                session_target = run_tmux(
                    tmux_binary,
                    socket_name,
                    "display-message",
                    "-p",
                    "-t",
                    origin,
                    "#{session_id}",
                ).strip()
                resolved = run_tmux(
                    tmux_binary,
                    socket_name,
                    "display-message",
                    "-p",
                    "-t",
                    session_target,
                    "#{pane_id}",
                ).strip()
                raise RuntimeError(
                    "initial preview did not render the originating pane token; "
                    f"session target resolved to {resolved}, origin was {origin}"
                )

        tiled = next(
            pane_id
            for pane_id, is_floating, _ in pane_rows(tmux_binary, socket_name)
            if is_floating == "0"
        )
        dimmed_style = run_tmux(
            tmux_binary,
            socket_name,
            "display-message",
            "-p",
            "-t",
            tiled,
            "#{E:window-style}",
        ).strip()
        if expected_base not in dimmed_style or "dim=60" not in dimmed_style:
            raise RuntimeError(f"inactive tiled pane was not dimmed: {dimmed_style!r}")

        run_tmux(tmux_binary, socket_name, "select-pane", "-t", tiled)
        focused_style = run_tmux(
            tmux_binary,
            socket_name,
            "display-message",
            "-p",
            "-t",
            tiled,
            "#{E:window-style}",
        ).strip()
        if "dim=60" in focused_style:
            raise RuntimeError(f"backdrop stayed dim after focus left switcher: {focused_style!r}")

        run_tmux(tmux_binary, socket_name, "select-pane", "-t", floating)
        replaced_hook = ""
        if scenario == "replace-hook":
            replaced_hook = run_tmux(
                tmux_binary, socket_name, "show-option", "-wqv", "-t",
                "integration:0", "@fzf_pane_switch_backdrop-hook",
            ).strip()
            run_tmux(tmux_binary, socket_name, "set-hook", "-w", "-t",
                     "integration:0", replaced_hook, "display-message external-hook")
        if external_style:
            run_tmux(
                tmux_binary,
                socket_name,
                "set-option",
                "-w",
                "-t",
                "integration:0",
                "window-style",
                external_style,
            )
        if scenario == "multi-client":
            os.write(fd, b"%1")
            time.sleep(0.15)
            os.write(fd, b"\r")
        else:
            run_tmux(tmux_binary, socket_name, "send-keys", "-t", floating, "Escape")
        closed = wait_for(
            lambda: not floating_pane(tmux_binary, socket_name), fd, transcript
        )
        if not closed:
            raise RuntimeError("floating switcher did not close")
        if scenario == "multi-client":
            def selected_origin():
                clients = run_tmux(tmux_binary, socket_name, "list-clients", "-F", "#{client_name} #{session_name}:#{window_index}").splitlines()
                return clients if f"{origin_client} integration:1" in clients and any(line.endswith(" observer:0") for line in clients) else None
            clients = wait_for(selected_origin, fd, transcript)
            if not clients:
                raise RuntimeError(f"selection switched the wrong client: {clients!r}")

        cleanup_finished = wait_for(
            lambda: run_tmux(
                tmux_binary,
                socket_name,
                "show-options",
                "-wqv",
                "-t",
                "integration:0",
                "window-style",
            ).strip()
            == expected_local
            and not run_tmux(
                tmux_binary,
                socket_name,
                "show-options",
                "-wqv",
                "-t",
                "integration:0",
                "@fzf_pane_switch_backdrop-owner",
            ).strip(),
            fd,
            transcript,
        )
        if not cleanup_finished:
            raise RuntimeError("backdrop cleanup did not finish")

        local_style = run_tmux(
            tmux_binary,
            socket_name,
            "show-options",
            "-wqv",
            "-t",
            "integration:0",
            "window-style",
        ).strip()
        if local_style != expected_local:
            raise RuntimeError(
                "window-style was not restored: "
                f"expected {expected_local!r}, got {local_style!r}"
            )

        hooks = run_tmux(
            tmux_binary,
            socket_name,
            "show-hooks",
            "-w",
            "-t",
            "integration:0",
        )
        if replaced_hook:
            if f"{replaced_hook} display-message external-hook" not in hooks:
                raise RuntimeError(f"external hook replacement was lost: {hooks!r}")
        elif "fzf-pane-switch" in hooks:
            raise RuntimeError(f"temporary backdrop hook remained: {hooks!r}")

        owner = run_tmux(
            tmux_binary,
            socket_name,
            "show-options",
            "-wqv",
            "-t",
            "integration:0",
            "@fzf_pane_switch_backdrop-owner",
        ).strip()
        if owner:
            raise RuntimeError(f"temporary backdrop owner remained: {owner!r}")
        return 0
    except Exception as error:
        read_available(fd, transcript)
        print(str(error), file=sys.stderr)
        print(f"pane rows: {pane_rows(tmux_binary, socket_name)!r}", file=sys.stderr)
        print(
            run_tmux(
                tmux_binary,
                socket_name,
                "show-options",
                "-w",
                "-t",
                "integration:0",
            ),
            file=sys.stderr,
        )
        print(transcript.decode("utf-8", errors="replace")[-4000:], file=sys.stderr)
        print(
            run_tmux(tmux_binary, socket_name, "show-messages", "-J", check=False)[-4000:],
            file=sys.stderr,
        )
        return 1
    finally:
        if observer_fd is not None:
            os.close(observer_fd)
        if observer_pid is not None:
            try:
                os.kill(observer_pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            os.waitpid(observer_pid, 0)
        try:
            os.close(fd)
        except OSError:
            pass
        try:
            os.kill(child_pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            os.waitpid(child_pid, 0)
        except ChildProcessError:
            pass


if __name__ == "__main__":
    sys.exit(main())
