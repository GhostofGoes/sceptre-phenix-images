#!/usr/bin/env python3
"""Boot one image recipe's disk under phenix and minimega and take its screenshots.

The image boots as the only VM of a phenix experiment, on a VLAN that a host
tap on the runner shares, so the runner reaches it at 10.77.0.10. Each shot in
.github/screenshots/shots.json is one of:

  screen   the VM's framebuffer as it is (minimega vm screenshot), after an
           optional guest command prints something
  console  commands run as root over C2, echoed with their output on tty1,
           then the framebuffer
  browser  a page the VM serves, opened by headless Chrome on the runner,
           after an optional guest command and once the page answers

The run also records facts about the booted image (OS, kernel, package count,
disk use, enabled services, listening ports, and the recipe's own version
commands) for the report.

Usage: sudo -E python3 run_screenshots.py <recipe> <shots.json> <out dir>
"""

import base64
import json
import os
import shlex
import socket
import subprocess
import sys
import time
from pathlib import Path

PHENIX = ["phenix", "--store.endpoint", "bolt:///etc/phenix/store.bdb"]
IMAGES = Path("/phenix/images")
MM_SOCKET = "/tmp/minimega/minimega"
EXP = "shots"
GUEST = "10.77.0.10"


def run(cmd, timeout=300):
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, check=False)
        return p.returncode == 0, (p.stdout + p.stderr).strip()
    except subprocess.TimeoutExpired:
        return False, f"timed out after {timeout} s: {cmd}"


def mm_resp(command, ns=EXP, timeout=300):
    if ns:
        command = f'namespace "{ns}" {command}'
    s = socket.socket(socket.AF_UNIX)
    s.settimeout(timeout)
    s.connect(MM_SOCKET)
    s.sendall(json.dumps({"Command": command}).encode())
    dec = json.JSONDecoder()
    buf, resps, done = "", [], False
    while not done:
        chunk = s.recv(65536)
        if not chunk:
            break
        buf += chunk.decode(errors="replace")
        while buf.strip():
            try:
                obj, end = dec.raw_decode(buf.lstrip())
            except json.JSONDecodeError:
                break
            buf = buf.lstrip()[end:]
            if obj.get("Status"):
                continue
            resps += obj.get("Resp") or []
            if not obj.get("More"):
                done = True
                break
    s.close()
    return resps


def mm(command, ns=EXP):
    rows, errs = [], []
    for r in mm_resp(command, ns):
        if r.get("Error"):
            errs.append(r["Error"])
        hdr = r.get("Header") or []
        rows += [dict(zip(hdr, row)) for row in r.get("Tabular") or []]
    return rows, errs


def guest(vm, script, wait=180):
    """Run script with bash in the guest over C2; return its stdout or None."""
    rows, _ = mm(".columns name,uuid vm info")
    uuid = next((r.get("uuid", "").lower() for r in rows if r.get("name") == vm), "")
    if not uuid:
        return None
    start, end = f"@@start-{time.time_ns()}@@", f"@@end-{time.time_ns()}@@"
    enc = base64.b64encode(f"echo {start}\n{script}\necho {end}".encode()).decode()
    mm(f"cc filter uuid={uuid}")
    resps = mm_resp(f"cc exec bash -c 'eval \"$(echo {enc} | base64 -d)\"'")
    mm("clear cc filter")
    # minimega returns the new command's ID as the response's Data.
    cid = next((str(r["Data"]) for r in resps if isinstance(r.get("Data"), int)), "")
    if not cid:
        return None
    base = IMAGES / EXP / "miniccc_responses" / cid
    t0 = time.time()
    try:
        while time.time() - t0 < wait:
            for d in base.glob("*") if base.is_dir() else []:
                out = d / "stdout"
                if d.name.lower() == uuid and out.exists():
                    t = out.read_text(errors="replace")
                    if t.startswith(start) and end in t:
                        return t[len(start):].split(end)[0].strip("\n")
            time.sleep(2)
        return None
    finally:
        mm(f"cc delete command {cid}")


def console_script(host, title, commands, gui, clear=True):
    """A script that shows commands and their output on tty1, as an interactive
    root shell would, and prints the same text. Without clear, the text goes
    below what the console already shows (the login prompt)."""
    lines = ["dmesg -n 1 2>/dev/null || true"]
    if gui:
        lines.append("chvt 1")
    lines += ["{"]
    if clear:
        lines.append("printf '\\033[2J\\033[H'")
    lines.append(f"printf '\\033[1;36m# %s\\033[0m\\n' {shlex.quote(title)}")
    for c in commands:
        lines.append(f"printf '\\033[1;32mroot@%s\\033[0m:\\033[1;34m~\\033[0m# %s\\n' {shlex.quote(host)} {shlex.quote(c)}")
        # The pattern drops this script's own processes from process trees
        # (its base64 starts with "echo @@start").
        lines.append(f"( {c} ) 2>&1 | grep -v -E 'ZWNobyBAQHN0YXJ0|tee /dev/tty1|cut -c1-126' | cut -c1-126")
    lines += ["} | tee /dev/tty1", "sleep 2"]
    return "\n".join(lines)


def screenshot(vm, path):
    errs = [r["Error"] for r in mm_resp(f"vm screenshot {vm} file {path}") if r.get("Error")]
    return not errs and Path(path).exists(), errs


def chrome(url, path):
    browser = next((b for b in ("google-chrome", "chromium", "chromium-browser") if run(["which", b])[0]), None)
    if not browser:
        return False, "no Chrome on the runner"
    return run([browser, "--headless=new", "--no-sandbox", "--disable-gpu", "--hide-scrollbars",
                "--window-size=1280,800", "--virtual-time-budget=15000", f"--screenshot={path}", url], timeout=120)


def wait_http(url, wait, ready=None):
    t0, last = time.time(), ""
    while time.time() - t0 < wait:
        ok, body = run(["curl", "-s", "--max-time", "5", "-w", "\n%{http_code}", url], timeout=10)
        code = body.rsplit("\n", 1)[-1] if body else ""
        last = code
        if code and code != "000" and int(code) < 500 and (not ready or ready in body):
            return True, code
        time.sleep(5)
    return False, last


def main():
    recipe, spec_path, out = sys.argv[1], Path(sys.argv[2]), Path(sys.argv[3])
    spec = json.loads(spec_path.read_text())[recipe]
    out.mkdir(parents=True, exist_ok=True)
    gui = bool(spec.get("gui"))
    vm = recipe
    res = {"recipe": recipe, "spec": {k: spec.get(k) for k in ("vcpus", "memory", "gui", "nics")}, "shots": [], "facts": {}}

    def save():
        (out / "manifest.json").write_text(json.dumps(res, indent=1))

    ifaces = [{"name": "IF0", "type": "ethernet", "proto": "static", "address": GUEST, "mask": 24, "vlan": "SHOT"}]
    if spec.get("nics", 1) > 1:
        ifaces.append({"name": "IF1", "type": "ethernet", "proto": "manual", "vlan": "MIRROR"})
    topo = {"apiVersion": "phenix.sandia.gov/v1", "kind": "Topology", "metadata": {"name": EXP},
            "spec": {"nodes": [{"type": "VirtualMachine", "general": {"hostname": vm},
                                "hardware": {"os_type": "linux", "vcpus": spec["vcpus"], "memory": spec["memory"],
                                             "drives": [{"image": f"{recipe}.qc2"}]},
                                "network": {"interfaces": ifaces}}]}}
    work = Path("/tmp/shots-ci")
    work.mkdir(exist_ok=True)
    (work / "topology.json").write_text(json.dumps(topo))
    for args in (["config", "create", str(work / "topology.json")], ["experiment", "create", EXP, "-t", EXP],
                 ["experiment", "start", EXP]):
        ok, text = run([*PHENIX, *args], timeout=900)
        if not ok:
            res["error"] = f"phenix {' '.join(args)}: {text[-1500:]}"
            save()
            return 1
    t0 = time.time()
    while time.time() - t0 < 900:
        rows, _ = mm("cc clients")
        if any(r.get("hostname") == vm for r in rows):
            break
        time.sleep(5)
    else:
        res["error"] = "the guest never reached C2"
        screenshot(vm, out / "no-c2.png")
        save()
        return 1
    res["facts"]["c2_seconds"] = round(time.time() - t0)
    errs = [r["Error"] for r in mm_resp("tap create SHOT bridge phenix ip 10.77.0.1/24 shot0") if r.get("Error")]
    if errs:
        res["error"] = f"tap create: {errs}"
        save()
        return 1
    time.sleep(spec.get("settle", 10))

    facts = {
        "os": ". /etc/os-release && echo \"$PRETTY_NAME\"",
        "kernel": "uname -r",
        "packages": "dpkg-query -f '.\\n' -W | wc -l",
        "disk_used": "df -h --output=used / | tail -1 | tr -d ' '",
        "memory_mb": "free -m | awk '/^Mem/ {print $2}'",
        "enabled_services": "systemctl list-unit-files --type=service --state=enabled --no-legend | awk '{print $1}' | xargs",
        "listening": "ss -Hltn | awk '{print $4}' | sort -u | xargs",
    }
    for key, cmd in facts.items():
        res["facts"][key] = guest(vm, cmd, 60)
    res["facts"]["versions"] = {c: guest(vm, c, 60) for c in spec.get("versions", [])}
    ok, info = run(["qemu-img", "info", "--output", "json", str(IMAGES / f"{recipe}.qc2")])
    if ok:
        q = json.loads(info)
        res["facts"]["image_bytes"] = q.get("actual-size")
        res["facts"]["virtual_bytes"] = q.get("virtual-size")
    save()

    for i, shot in enumerate(spec["shots"], 1):
        rec = {"n": i, "title": shot["title"], "kind": shot["kind"], "file": f"{i}.png"}
        path = out / rec["file"]
        # wait: a guest command that prints something once the guest is ready
        # for the shot; prep: a guest command run after that.
        if shot.get("wait") and shot["kind"] != "browser":
            t1 = time.time()
            while time.time() - t1 < 600 and not (guest(vm, shot["wait"], 30) or "").strip():
                time.sleep(5)
        if shot.get("prep"):
            rec["prep"] = shot["prep"]
            guest(vm, shot["prep"], 660)
        if shot["kind"] == "screen":
            time.sleep(shot.get("delay", 10))
            rec["ok"], rec["errors"] = screenshot(vm, path)
        elif shot["kind"] == "console":
            rec["commands"] = shot["commands"]
            rec["output"] = guest(vm, console_script(vm, shot["title"], shot["commands"], gui, shot.get("clear", True)), 180)
            rec["ok"], rec["errors"] = screenshot(vm, path)
            if gui:
                guest(vm, "chvt 7", 30)
        elif shot["kind"] == "browser":
            rec["url"] = shot["url"]
            up, code = wait_http(shot["url"], shot.get("wait", 120), shot.get("ready"))
            rec["http"] = code
            time.sleep(5)
            ok, text = chrome(shot["url"], str(path))
            rec["ok"] = up and ok and path.exists()
            rec["errors"] = [] if rec["ok"] else [f"page ready {up} (HTTP {code}); chrome: {text[-500:]}"]
        res["shots"].append(rec)
        print(f"{recipe} shot {i} {shot['title']}: {'ok' if rec.get('ok') else 'FAILED ' + str(rec.get('errors'))}", flush=True)
        save()

    run([*PHENIX, "experiment", "stop", EXP], timeout=600)
    res["ok"] = all(s.get("ok") for s in res["shots"]) and len(res["shots"]) == len(spec["shots"])
    save()
    return 0 if res["ok"] else 1


if __name__ == "__main__":
    os.umask(0o022)
    sys.exit(main())
