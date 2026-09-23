#!/usr/bin/env python3
"""Interactive CallBridge agent probe.

Connects to callbridge-agent, pairs over HMAC, prints every event and lets you issue
commands by hand. Stands in for the Android client until it exists.

    python3 scripts/mac/agent-probe.py 192.168.1.109 <token>

Keys: a = answer, h = hangup, s = status of the tracked call, q = quit.
"""

import hashlib
import hmac
import json
import socket
import sys
import threading
import uuid

PORT = 8765


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 2

    host, token = sys.argv[1], sys.argv[2]
    port = int(sys.argv[3]) if len(sys.argv) > 3 else PORT

    connection = socket.create_connection((host, port), timeout=10)
    connection.settimeout(None)
    stream = connection.makefile("rw", encoding="utf-8", newline="\n")

    write_lock = threading.Lock()
    tracked = {"callId": None, "state": None}

    def send(message):
        with write_lock:
            stream.write(json.dumps(message) + "\n")
            stream.flush()

    hello = json.loads(stream.readline())
    print(f"<< hello: agent {hello.get('agentVersion')} on {hello.get('device')}, "
          f"protocol v{hello.get('protocolVersion')}")

    proof = hmac.new(token.encode(), hello["nonce"].encode(), hashlib.sha256).hexdigest()
    send({"type": "auth", "protocolVersion": 1, "clientName": "mac-probe", "proof": proof})

    def reader():
        for line in stream:
            try:
                message = json.loads(line)
            except json.JSONDecodeError:
                print("<< unparseable:", line.strip())
                continue

            kind = message.get("type")

            # Answer keepalives silently; an unanswered ping gets us disconnected.
            if kind == "ping":
                send({"type": "pong"})
                continue

            if kind == "call.state":
                tracked["state"] = message.get("state")
                tracked["callId"] = (message["callId"]
                                     if message.get("state") in ("ringing", "active") else None)
                print(f"<< call.state: {message.get('state'):8} {message.get('address', '?')} "
                      f"({message.get('callId')})")
                continue

            if kind == "call.result":
                if message.get("ok"):
                    print(f"<< call.result: {message.get('command')} OK "
                          f"{message.get('fromState')} -> {message.get('toState')} "
                          f"in {message.get('elapsedMs')} ms, seen {message.get('observedStates')}")
                else:
                    error = message.get("error", {})
                    print(f"<< call.result: {message.get('command')} FAILED "
                          f"{error.get('code')} - {error.get('message')} "
                          f"seen {message.get('observedStates')}")
                continue

            print("<<", json.dumps(message))

        print("!! connection closed by the agent")

    threading.Thread(target=reader, daemon=True).start()

    print("keys: a = answer, h = hangup, s = tracked call, q = quit")
    for key in iter(lambda: sys.stdin.readline().strip(), "q"):
        if key == "s":
            print(f">> tracked: {tracked}")
        elif key in ("a", "h"):
            command = "answer" if key == "a" else "hangup"
            send({"type": "call.command", "requestId": str(uuid.uuid4()),
                  "command": command, "callId": tracked["callId"]})
            print(f">> sent {command} for {tracked['callId']}")
        elif key:
            print("?? unknown key")

    return 0


if __name__ == "__main__":
    sys.exit(main())
