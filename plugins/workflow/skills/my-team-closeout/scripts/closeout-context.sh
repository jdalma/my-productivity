#!/usr/bin/env bash
# closeout-context.sh [worker-name]
# my-team closeout 에 필요한 컨텍스트를 JSON 한 덩어리로 출력한다(읽기 전용).
# 인자 없음 = 이 pane 의 워커(보고자 모드). 인자 있음 = 그 워커를 조사(수신자 모드).
# 출력: team, state_root, worker, spawner, orchestrators, tickets(수신한 expects_reply 메시지),
#       sent_pending, status, report_path(+존재 여부), git(cwd 기준), roster
set -u
ID="${MY_TEAM_WORKER:-${OMC_TEAM_WORKER:-}}"
if [ -z "$ID" ]; then echo '{"ok":false,"error":"MY_TEAM_WORKER/OMC_TEAM_WORKER 비어 있음 — my-team 워커 pane 이 아니다"}'; exit 1; fi
TEAM="${ID%%/*}"; ME="${ID#*/}"
TARGET="${1:-$ME}"
ROOT="${MY_TEAM_STATE_ROOT:-${MY_TEAM_STATE_ROOT_BASE:-$HOME/.my-team/sessions}/$TEAM}"
ROSTER=$(my-team api roster --input "{\"team_name\":\"$TEAM\"}" --json 2>/dev/null || echo '{}')
MAILBOX=$(my-team api mailbox-list --input "{\"team_name\":\"$TEAM\",\"worker\":\"$ME\"}" --json 2>/dev/null || echo '{}')
CWD=$(python3 -c "import json,sys; m=json.load(open('$ROOT/manifest.json')); print(next((w['cwd'] for w in m['workers'] if w['name']=='$TARGET'),''))" 2>/dev/null || echo "")
GIT="{}"
if [ -n "$CWD" ] && git -C "$CWD" rev-parse --git-dir >/dev/null 2>&1; then
  GIT=$(python3 - "$CWD" <<'PY'
import subprocess,sys,json
c=sys.argv[1]
def g(*a):
    try: return subprocess.check_output(["git","-C",c,*a],stderr=subprocess.DEVNULL,text=True).strip()
    except Exception: return None
print(json.dumps({"cwd":c,"branch":g("rev-parse","--abbrev-ref","HEAD"),"head":g("rev-parse","--short","HEAD"),
 "dirty":bool(g("status","--porcelain")),"upstream":g("rev-parse","--abbrev-ref","@{u}"),
 "ahead_behind":g("rev-list","--left-right","--count","@{u}...HEAD"),"is_worktree":".worktrees/" in c}))
PY
)
fi
python3 - "$ROOT" "$TEAM" "$ME" "$TARGET" "$ROSTER" "$MAILBOX" "$GIT" <<'PY'
import json,sys,re,os,pathlib
root,team,me,target,roster,mailbox,git=sys.argv[1:8]
roster=json.loads(roster or '{}'); mailbox=json.loads(mailbox or '{}')
rows=roster.get('roster') or roster.get('workers') or []
orch=[w['name'] for w in rows if w.get('role')=='orchestrator']
agents=pathlib.Path(root)/'workers'/target/'AGENTS.md'
txt=agents.read_text() if agents.exists() else ''
rc=txt.rsplit('\n## Role Context',1)[1] if '\n## Role Context' in txt else ''   # 마지막 헤더 기준 — Rules 본문의 '## Role Context' 언급·spawn 템플릿 예문을 피한다
m=re.search(r'Spawned by ([A-Za-z0-9-]+)',rc) or re.search(r'Message ([A-Za-z0-9-]+) ONLY',rc)
spawner=m.group(1) if m else (orch[0] if orch else None)
tickets=[]
arch=pathlib.Path(root)/'archive'/f'{target}.jsonl'
if arch.exists():
    for l in arch.read_text().splitlines():
        try: e=json.loads(l)
        except Exception: continue
        if e.get('direction')=='in' and e.get('expects_reply') and not e.get('reply_to'):
            tickets.append({k:e.get(k) for k in ('message_id','from_worker','created_at')}|{'body_head':(e.get('body') or '')[:160]})
status={}
sp=pathlib.Path(root)/'workers'/target/'status.json'
if sp.exists():
    try: status=json.loads(sp.read_text())
    except Exception: status={'raw':sp.read_text()[:200]}
report=pathlib.Path(root)/'workers'/target/'closeout-report.md'
print(json.dumps({"ok":True,"team":team,"state_root":root,"me":me,"worker":target,"mode":"reporter" if target==me else "receiver",
 "spawner":spawner,"spawner_source":"role_context" if m else ("orchestrator_fallback" if spawner else None),
 "orchestrators":orch,"tickets":tickets,"sent_pending":mailbox.get('sent_pending',[]),"unread":len(mailbox.get('messages',[])),
 "status":status,"report_path":str(report),"report_exists":report.exists(),"git":json.loads(git or '{}'),
 "roster":[{k:w.get(k) for k in ('name','role','description')} for w in rows]},ensure_ascii=False,indent=1))
PY
