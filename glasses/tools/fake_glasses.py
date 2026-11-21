#!/usr/bin/env python3
"""Stand-in for the BuildLens glasses app, for testing without the glasses (macOS only).

It does what the real glasses app does on the network: advertises `_buildlens-glass._tcp`
on port 52733 and speaks newline-separated JSON, `{"step": N, "finished": false}`.
Run it on a Mac that is on the same Wi-Fi as the iPhone, then open BuildLens on the
iPhone: it should show the glasses as linked, and every step change prints here.

    python3 glasses/tools/fake_glasses.py

Type a key + Enter, as if you clicked the button on the glasses:
`n` next (one click), `r` replay this step (two clicks), `b` back (three clicks), `q` quit.
"""
import json
import socket
import subprocess
import sys
import threading

PORT = 52733
STEPS = 23

clients = []
state = {"step": 0, "finished": False}
lock = threading.Lock()


def send_all(replay=False):
    line = (json.dumps(dict(state, replay=True) if replay else state) + "\n").encode()
    for c in list(clients):
        try:
            c.sendall(line)
        except OSError:
            clients.remove(c)


def show(source):
    label = "DONE" if state["finished"] else f"STEP {state['step'] + 1}/{STEPS}"
    print(f"[{source}] glasses would show: {label}", flush=True)


def read_loop(conn, addr):
    print(f"phone linked from {addr[0]}", flush=True)
    try:
        conn.sendall((json.dumps(dict(state, hello=True)) + "\n").encode())      # greeting, like the real app
        for line in conn.makefile("r", encoding="utf-8"):
            try:
                msg = json.loads(line)
            except ValueError:
                continue
            if "step" in msg:
                with lock:
                    state["step"] = int(msg["step"])
                    state["finished"] = bool(msg.get("finished", False))
                show("from phone, replay" if msg.get("replay") else "from phone")
    except OSError:
        pass
    finally:
        if conn in clients:
            clients.remove(conn)
        print("phone unlinked", flush=True)


def accept_loop(server):
    while True:
        conn, addr = server.accept()
        conn.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        clients.append(conn)
        threading.Thread(target=read_loop, args=(conn, addr), daemon=True).start()


def main():
    server = socket.socket(socket.AF_INET6, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
    server.bind(("::", PORT))
    server.listen()
    advert = subprocess.Popen(
        ["dns-sd", "-R", "BuildLens Glasses (fake)", "_buildlens-glass._tcp", "local", str(PORT)],
        stdout=subprocess.DEVNULL,
    )
    threading.Thread(target=accept_loop, args=(server,), daemon=True).start()
    print(f"Fake glasses advertising _buildlens-glass._tcp on port {PORT}. n = next, r = replay, b = back, q = quit.", flush=True)
    try:
        for line in sys.stdin:
            key = line.strip().lower()
            if key == "q":
                break
            with lock:
                if key == "n":
                    if state["finished"]:
                        continue
                    if state["step"] + 1 < STEPS:
                        state["step"] += 1
                    else:
                        state["finished"] = True
                elif key == "b":
                    if state["finished"]:
                        state["finished"] = False
                    elif state["step"] > 0:
                        state["step"] -= 1
                elif key != "r":
                    continue
            show("button, replay" if key == "r" else "button")
            send_all(replay=key == "r")
        else:
            # stdin closed (run in the background): keep serving until killed.
            threading.Event().wait()
    except KeyboardInterrupt:
        pass
    finally:
        advert.terminate()


if __name__ == "__main__":
    main()
