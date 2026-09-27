#!/usr/bin/env python3
# A fake keep-worktrees: its answers come from files the test writes in
# $FAKE_DIR, and every call is logged there (calls.log). The commands and
# keys are the real helper's.
import json, os, sys, time
d = os.environ["FAKE_DIR"]
log = open(os.path.join(d, "calls.log"), "a")
def alive(pid):
    try: os.kill(int(pid), 0); return True
    except Exception: return False
watched = os.environ.get("FAKE_PID")
log.write(json.dumps({"argv": sys.argv[1:], "socket": os.environ.get("KEEP_SOCKET"), "pid_alive": alive(watched) if watched else None}) + "\n"); log.close()
cmd = sys.argv[1]
def answer(name, default):
    p = os.path.join(d, name)
    return json.load(open(p)) if os.path.exists(p) else default
if cmd == "listar":
    time.sleep(float(answer("listar-delay.json", 0)))
    print(json.dumps(answer("listar.json", {"versao": 1})))
elif cmd == "preparar":
    path = sys.argv[2]
    n = os.path.join(d, "preparar-" + os.path.basename(path) + ".json")
    seq = json.load(open(n)) if os.path.exists(n) else [{"versao": 1, "ok": True}]
    r = seq.pop(0) if len(seq) > 1 else seq[0]
    json.dump(seq, open(n, "w"))
    print(json.dumps(r))
elif cmd == "concluir":
    print(json.dumps({"versao": 1, "ok": os.path.exists(sys.argv[2]) is False, "motivo": "still there" if os.path.exists(sys.argv[2]) else None}))
else:
    sys.exit(3)
