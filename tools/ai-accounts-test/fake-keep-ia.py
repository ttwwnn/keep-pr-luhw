#!/usr/bin/env python3
"""A stand-in for `keep-ia`, the helper outside the app that keeps the order
of the AI accounts, makes logins and moves a tab to another account, for the
app's tests.

It answers as keep-ia does — `--json`, one object printed, "versao": 1, exit
0 for ok and 1 for not, its commands, options and keys its own — out of a
home and a state directory of the test's own, never the real ones:

  ordem --json
  ordem mover <key> cima|baixo --json
      the order in <home>/.claude/contas/.ordem, with every account the home
      holds that it does not list yet put at its end, the key moved one
      place, written back whole (a new file, as keep-ia writes it)
  entrar claude|gpt --ws=<W> --json
      a new tab in W, opened with the client named in FAKE_IA_KEEP, and the
      login keep-ia would have made there: a slot "new" in the vault, or a
      folder "new" in .codex-contas, put at the end of the order
  trocar --ws=<W> --aba=<N> --para=<key> [--interromper] --json
      the tab's account written into <state>/retrato.json's "ia" list

Every call is logged, one JSON line each, to $FAKE_IA_DIR/calls.jsonl: its
arguments and the socket it was told to use. Files in $FAKE_IA_DIR change
how it answers:
  slow      seconds to wait before answering anything
  fail      `ordem mover` says no
  busy      `trocar` without --interromper says the tab is busy
  needs-login
            `trocar` opens a tab in the workspace, as the kit does for an
            account with no login of its own for tabs yet, and says so: the
            motivo "precisa-login", with "aba_login" and "ws_login"
  error     `trocar` says no, with this file's text as the reason

The home is KEEP_AI_USAGE_HOME and the state KIT_KEEP_ESTADO: the ones the
app under test was given, which it hands on to its helper.
"""

import base64
import json
import os
import re
import subprocess
import sys
import time

DIR = os.environ.get("FAKE_IA_DIR") or os.path.dirname(os.path.abspath(__file__))
HOME = os.environ.get("KEEP_AI_USAGE_HOME") or "/nonexistent"
STATE = os.environ.get("KIT_KEEP_ESTADO") or "/nonexistent"
VAULT = os.path.join(HOME, ".claude", "contas")
ORDER = os.path.join(VAULT, ".ordem")
KEY = re.compile(r"^(claude|gpt):[^\s/:]+$")


def flag(name):
    return os.path.join(DIR, name)


def log(argv):
    with open(flag("calls.jsonl"), "a", encoding="utf-8") as out:
        out.write(json.dumps({"argv": argv, "socket": os.environ.get("KEEP_SOCKET")}) + "\n")


def answer(body, ok=True):
    body = dict(body)
    body.setdefault("versao", 1)
    body["ok"] = ok
    print(json.dumps(body, ensure_ascii=False))
    sys.exit(0 if ok else 1)


def refuse(motivo, detalhe):
    answer({"motivo": motivo, "detalhe": detalhe}, ok=False)


def read_json(path):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def write_atomically(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    temporary = path + ".tmp-%d" % os.getpid()
    with open(temporary, "w", encoding="utf-8") as f:
        f.write(text)
    os.replace(temporary, path)


def slot_name(path):
    try:
        with open(path, encoding="utf-8") as f:
            return f.read().strip() or None
    except OSError:
        return None


# ------------------------------------------------------------------ accounts


def accounts_in_todays_order():
    """Every account's key, Claude first — the preferred one, then by name,
    one key per login — then GPT: the principal, then the extras by name."""
    active = slot_name(os.path.join(VAULT, ".ativa"))
    preferred = slot_name(os.path.join(VAULT, ".preferida"))
    by_owner = {}
    try:
        names = sorted(os.listdir(VAULT))
    except OSError:
        names = []
    for name in names:
        if not name.endswith(".json") or name.startswith("."):
            continue
        slot = read_json(os.path.join(VAULT, name)) or {}
        alias = slot.get("apelido") or name[: -len(".json")]
        owner = slot.get("accountUuid") or slot.get("email") or alias
        by_owner.setdefault(owner, []).append(alias)
    claude = []
    for aliases in by_owner.values():
        # One key per login: the one the tabs know it by.
        shown = next((a for a in aliases if a == active), None) or next(
            (a for a in aliases if a == preferred), None) or sorted(aliases)[0]
        claude.append((0 if preferred in aliases else 1, shown))
    keys = ["claude:" + alias for _, alias in sorted(claude)]
    if os.path.exists(os.path.join(HOME, ".codex", "auth.json")):
        keys.append("gpt:principal")
    extras = os.path.join(HOME, ".codex-contas")
    try:
        for name in sorted(os.listdir(extras)):
            if not name.startswith(".") and os.path.exists(os.path.join(extras, name, "auth.json")):
                keys.append("gpt:" + name)
    except OSError:
        pass
    return keys


def full_order():
    listed = []
    try:
        with open(ORDER, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith("#") and line not in listed:
                    listed.append(line)
    except OSError:
        pass
    return listed + [key for key in accounts_in_todays_order() if key not in listed]


def jwt(claims):
    part = base64.urlsafe_b64encode(json.dumps(claims).encode()).decode().rstrip("=")
    return "h." + part + ".s"


# ------------------------------------------------------------------ commands


def ordem(argv):
    if argv[1:2] == ["mover"]:
        if len(argv) < 4 or not KEY.match(argv[2]) or argv[3] not in ("cima", "baixo"):
            sys.exit(2)
        if os.path.exists(flag("fail")):
            refuse("erro", "simulated keep-ia failure")
        order = full_order()
        key = argv[2]
        if key not in order:
            order.append(key)
        at = order.index(key)
        to = at - 1 if argv[3] == "cima" else at + 1
        if 0 <= to < len(order):
            order[at], order[to] = order[to], order[at]
            write_atomically(ORDER, "\n".join(order) + "\n")
        answer({"ordem": order})
    answer({"ordem": full_order()})


def option(argv, name):
    for item in argv:
        if item.startswith("--" + name + "="):
            return item.split("=", 1)[1]
    return None


def entrar(argv):
    service = argv[1] if len(argv) > 1 else ""
    workspace = option(argv, "ws")
    if service not in ("claude", "gpt") or not workspace:
        sys.exit(2)
    keep = os.environ.get("FAKE_IA_KEEP")
    if not keep:
        refuse("erro", "FAKE_IA_KEEP was not given")
    made = subprocess.run([keep, "new", workspace], capture_output=True, text=True)
    found = re.search(r"opened tab (\d+)", made.stdout)
    if not found:
        refuse("erro", "could not open the tab: " + (made.stderr or made.stdout).strip())
    now = time.time()
    if service == "gpt":
        folder = os.path.join(HOME, ".codex-contas", "new")
        os.makedirs(folder, exist_ok=True)
        claims = {"exp": int(now + 86400),
                  "https://api.openai.com/profile": {"email": "new@example.com"},
                  "https://api.openai.com/auth": {"chatgpt_plan_type": "plus",
                                                  "chatgpt_account_id": "ACC-NEW"}}
        body = {"auth_mode": "chatgpt",
                "tokens": {"access_token": jwt(claims), "account_id": "ACC-NEW",
                           "refresh_token": "never-used"}}
        write_atomically(os.path.join(folder, "auth.json"), json.dumps(body))
        new_key = "gpt:new"
    else:
        body = {"apelido": "new", "email": "new@example.com", "accountUuid": "U-NEW",
                "credenciais": {"claudeAiOauth": {
                    "accessToken": "tok-new", "refreshToken": "never-used",
                    "expiresAt": int((now + 5 * 3600) * 1000),
                    "subscriptionType": "max", "rateLimitTier": "default_claude_max_20x"}}}
        write_atomically(os.path.join(VAULT, "new.json"), json.dumps(body))
        new_key = "claude:new"
    if os.path.exists(ORDER):
        order = full_order()
        if new_key not in order:
            order.append(new_key)
        write_atomically(ORDER, "\n".join(order) + "\n")
    answer({"ws": workspace, "aba": int(found.group(1))})


def trocar(argv):
    workspace, tab, key = option(argv, "ws"), option(argv, "aba"), option(argv, "para")
    if not workspace or not tab or not tab.isdigit() or not key or not KEY.match(key):
        sys.exit(2)
    if os.path.exists(flag("busy")) and "--interromper" not in argv:
        refuse("ocupada", "The tab is in the middle of an answer.")
    if os.path.exists(flag("needs-login")):
        keep = os.environ.get("FAKE_IA_KEEP")
        made = subprocess.run([keep, "new", workspace], capture_output=True, text=True) if keep else None
        found = re.search(r"opened tab (\d+)", made.stdout) if made else None
        if not found:
            refuse("erro", "could not open the login's tab")
        answer({"motivo": "precisa-login", "aba_login": int(found.group(1)), "ws_login": workspace,
                "detalhe": "The account has no login of its own for tabs yet. The login is open in a tab: "
                           "approve it there and this tab moves to the account by itself."}, ok=False)
    if os.path.exists(flag("error")):
        with open(flag("error"), encoding="utf-8") as f:
            refuse("erro", f.read().strip() or "simulated error")
    retrato = os.path.join(STATE, "retrato.json")
    photo = read_json(retrato)
    if isinstance(photo, dict):
        entries = [e for e in photo.get("ia") or []
                   if not (e.get("workspace") == workspace and e.get("aba") == int(tab))]
        entries.append({"workspace": workspace, "aba": int(tab),
                        "agente": "codex" if key.startswith("gpt:") else "claude",
                        "conta": key, "vinculo": "exato"})
        photo["ia"] = entries
        photo["gravado_em_ms"] = int(time.time() * 1000)
        write_atomically(retrato, json.dumps(photo))
    answer({"feito": "tab %s/%s on %s" % (workspace, tab, key)})


def main():
    argv = sys.argv[1:]
    log(argv)
    try:
        with open(flag("slow"), encoding="utf-8") as f:
            time.sleep(float(f.read().strip() or "0"))
    except (OSError, ValueError):
        pass
    if "--json" not in argv or not argv:
        sys.exit(2)
    argv = [item for item in argv if item != "--json"]
    commands = {"ordem": ordem, "entrar": entrar, "trocar": trocar}
    if argv[0] not in commands:
        sys.exit(2)
    commands[argv[0]](argv)


if __name__ == "__main__":
    main()
