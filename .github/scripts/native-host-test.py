#!/usr/bin/env python3
"""Talks to CosmoGrav the way Chrome does (native messaging) and checks the answers.
Usage: native-host-test.py /path/to/CosmoGrav.app/Contents/MacOS/CosmoGrav"""
import json, os, struct, subprocess, sys

EXE = sys.argv[1]
ORIGIN = "chrome-extension://bkpidlfkklifiknphemnicbhdfnidmhj/"
INBOX = os.path.expanduser("~/Library/Application Support/TeamYTDownloader/browser-inbox")
failures = 0

def check(ok, name):
    global failures
    print(("PASS  " if ok else "FAIL  ") + name)
    failures += 0 if ok else 1

def talk(messages, origin=ORIGIN):
    data = b"".join(struct.pack("<I", len(b)) + b for b in (json.dumps(m).encode() for m in messages))
    env = dict(os.environ, COSMOGRAV_NO_OPEN="1")
    p = subprocess.run([EXE, origin, "--parent-window=0"], input=data, capture_output=True, env=env, timeout=30)
    out, replies = p.stdout, []
    while len(out) >= 4:
        n = struct.unpack("<I", out[:4])[0]
        replies.append(json.loads(out[4:4 + n]))
        out = out[4 + n:]
    return p.returncode, replies

for f in os.listdir(INBOX) if os.path.isdir(INBOX) else []:
    os.remove(os.path.join(INBOX, f))

code, r = talk([{"type": "hello", "extension": "1.7.0"}, {"type": "status"}])
check(code == 0 and len(r) == 2, "two answers in one session")
hello = r[0] if r else {}
print("      hello:", json.dumps(hello)[:300])
check(hello.get("ok") is True and hello.get("app") == hello.get("bundledExtension"), "hello reports app and matching extension version")
check(str(hello.get("extensionFolder", "")).endswith("CosmoGrav/Chrome Extension"), "extension folder reported")
check(os.path.isfile(os.path.join(hello.get("extensionFolder", "/nonexistent"), "manifest.json")), "extension folder filled")

code, r = talk([{"type": "add", "items": [{"url": "https://www.youtube.com/watch?v=3OMLs3yI-KE", "title": "Dutch GP"},
                                          {"url": "file:///etc/passwd"}], "quality": "hd1080", "start": True, "from": 5, "to": 20}])
check(r and r[0].get("ok") is True and r[0].get("added") == 1, "add accepted, file link dropped")
files = sorted(os.listdir(INBOX)) if os.path.isdir(INBOX) else []
check(len(files) == 1, "one request waiting in the inbox")
if files:
    req = json.load(open(os.path.join(INBOX, files[0])))
    check(req["items"] == [{"url": "https://www.youtube.com/watch?v=3OMLs3yI-KE", "title": "Dutch GP"}] and req["quality"] == "hd1080" and req["to"] == 20,
          "inbox request is clean")
    mode = os.stat(os.path.join(INBOX, files[0])).st_mode & 0o777
    check(mode == 0o600, "inbox file is private (%o)" % mode)
    for f in files: os.remove(os.path.join(INBOX, f))

code, r = talk([{"type": "add", "items": [{"url": "javascript:alert(1)"}]}])
check(r and r[0].get("ok") is False, "add with no usable link refused")

code, r = talk([{"type": "hello"}], origin="chrome-extension://aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/")
check(code != 0 and not r, "another extension is turned away")

big = struct.pack("<I", 5 * 1024 * 1024)
p = subprocess.run([EXE, ORIGIN], input=big, capture_output=True, timeout=30)
check(p.returncode != 0 and not p.stdout, "oversized message refused")

print("ALL PASSED" if failures == 0 else "%d FAILED" % failures)
sys.exit(1 if failures else 0)
