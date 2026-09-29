# topic-memory organiser (inlined into MEM_ORGANISE / MEM_REVIEW by 30_organiser.sql.j2).
#   organise(): per-insert triage. For each item in status 'new': fetch its nearest neighbours, ask
#               AI_COMPLETE for a structured decision, apply it through the MEM_ORG_* procedures.
#   review():   scheduled review. Triage leftovers, then hand the topic's organiser agent a review
#               brief (needs_review items, stale items) through DATA_AGENT_RUN.
# Every run is logged to MEM_ORGANISER_RUN.
import json
import time
import uuid
from datetime import date, datetime

FQ = "{{ fq }}"
OPEN = ("active", "new", "needs_review")
ACTOR = "organiser:pipeline"
DECISION_SCHEMA = {
    "type": "object",
    "properties": {
        "decision": {"type": "string", "enum": ["activate", "duplicate", "merge", "supersede", "reject", "escalate"]},
        "target_id": {"type": "string"},
        "reason": {"type": "string"},
        "title": {"type": "string"},
        "body": {"type": "string"},
        "category": {"type": "string"},
        "tags": {"type": "string"},
    },
    "required": ["decision", "target_id", "reason", "title", "body", "category", "tags"],
}


def _json(v):
    if v is None:
        return None
    return json.loads(v) if isinstance(v, str) else v


def _default(o):
    if isinstance(o, (date, datetime)):
        return o.isoformat()[:10]
    return str(o)


def _config(session, topic):
    rows = session.sql(f"SELECT CONFIG FROM {FQ}.MEM_TOPIC WHERE TOPIC_ID = ?", params=[topic]).collect()
    if not rows:
        raise ValueError(f"unknown topic {topic}")
    return _json(rows[0][0])


def _call(session, proc, *args):
    return _json(session.call(f"{FQ}.{proc}", *args))


def _start_run(session, topic, trigger, engine):
    run_id = uuid.uuid4().hex[:12]
    session.sql(f"INSERT INTO {FQ}.MEM_ORGANISER_RUN (RUN_ID, TOPIC_ID, TRIGGER_KIND, ENGINE, STARTED_AT) "
                "SELECT ?, ?, ?, ?, CURRENT_TIMESTAMP()", params=[run_id, topic, trigger, engine]).collect()
    return run_id


def _finish_run(session, run_id, items_in, actions, result, error):
    session.sql(f"UPDATE {FQ}.MEM_ORGANISER_RUN SET FINISHED_AT = CURRENT_TIMESTAMP(), ITEMS_IN = ?, "
                "ACTIONS = PARSE_JSON(?), RESULT = NULLIF(?, ''), ERROR = NULLIF(?, '') WHERE RUN_ID = ?",
                params=[items_in, json.dumps(actions, default=_default), result or "", error or "", run_id]).collect()


def _brief_text(cfg):
    b, s = cfg["brief"], cfg["schema"]
    cats = "\n".join(f"- {k}: {v}" for k, v in s["categories"].items())
    attrs = "\n".join(f"- {k} ({a['type']}{', required' if a.get('required') else ''}): {a['description']}"
                      for k, a in (s.get("attributes") or {}).items())
    return (f"Topic: {cfg['topic']['name']}\n{b['summary']}\n\nScope: {b['scope']}\n\n"
            f"Contributors save when: {b['contribute_when']}\n\nHow items must be written: {b['how_to_write']}\n\n"
            f"Never keep: {b['do_not_save']}\n\nCategories:\n{cats}\n\nAttributes:\n{attrs or '- none'}")


def _item_view(r, with_sim=False):
    v = {"id": r["ITEM_ID"], "status": r["STATUS"], "category": r["CATEGORY"], "title": r["TITLE"],
         "body": r["BODY"], "tags": _json(r["TAGS"]), "attributes": _json(r["ATTRIBUTES"]),
         "as_of_date": r["AS_OF_DATE"], "agent_type": r["AGENT_TYPE"]}
    if with_sim:
        v["similarity"] = round(float(r["SIM"]), 3)
    else:
        v["supersedes_hint"] = r["SUPERSEDES"]
    return v


def _decide(session, cfg, item, neighbours):
    noun = cfg["topic"]["item_noun"]
    prompt = f"""You are the organiser (curator) of a shared memory that several AI agents write to.

{_brief_text(cfg)}

Topic-specific curation rules:
{cfg['organiser'].get('triage_prompt') or '(none)'}

A contributor just saved the NEW {noun} below. Decide what happens to it, given the most similar existing {noun}s.
Decisions:
- activate: in scope, durable and not already covered. You may rewrite title/body/category/tags so they follow the
  writing rules (clearer wording, fully-qualified names), but keep every fact and never add facts, interpretations or
  cross-references that are not in the item itself - not even from the existing items below. If the item looks
  inconsistent with an existing item (e.g. its SQL uses a different filter), do not reconcile it: escalate.
- duplicate: an existing item (target_id) already states the same thing; the new item adds nothing.
- merge: the new item adds detail to an existing item (target_id) about the same fact. Give the merged
  title/body/category/tags FOR THE TARGET, keeping every fact from both.
- supersede: the new item corrects or replaces an existing item (target_id): it contradicts it with better evidence,
  or is a newer as-of value of the same measure. You may rewrite the new item.
- reject: out of scope, not durable (a one-off answer), unsupported speculation stated as fact, or personal data.
- escalate: you cannot decide safely, e.g. it contradicts an existing item and it is unclear which one is right.
The contributor's supersedes_hint (if any) says which item they believe theirs corrects: verify it, don't trust it.
If the item's category is 'uncategorised', set category to the best-fitting category above (any decision that
keeps or merges it).
Titles are index lines: specific, starting with the table or concept, without the as_of date (the index shows
as_of_date next to the title; put a missing date in the body instead).
Output rules: target_id must be one of the existing ids listed below ('' when the decision needs none). Use '' for
title/body/category/tags you leave unchanged. tags are comma-separated. reason is one sentence for the audit trail.

NEW ITEM:
{json.dumps(item, default=_default, indent=1)}

EXISTING SIMILAR ITEMS (most similar first):
{json.dumps(neighbours, default=_default, indent=1) if neighbours else '(none)'}
"""
    # (no f-string here: this file goes through Jinja, which would read a doubled brace as a tag)
    rf = json.dumps({"type": "json", "schema": DECISION_SCHEMA}).replace("'", "''")
    raw = session.sql(
        "SELECT AI_COMPLETE(model => ?, prompt => ?, model_parameters => {'temperature': 0, 'max_tokens': 8192}, "
        "response_format => PARSE_JSON('" + rf + "'))",
        params=[cfg["organiser"]["model"], prompt]).collect()[0][0]
    return _json(raw)


def _apply(session, topic, item_id, d, valid_targets):
    kind, target, reason = d["decision"], (d.get("target_id") or "").strip().upper(), d.get("reason") or "no reason"
    rewrite = [d.get(k) or "" for k in ("title", "body", "category", "tags")]
    if kind in ("duplicate", "merge", "supersede") and target not in valid_targets:
        kind, reason = "escalate", f"organiser chose {d['decision']} with invalid target '{target}': {reason}"
    steps = []

    def update(iid):
        if any(rewrite):
            steps.append(_call(session, "MEM_ORG_UPDATE_ITEM", topic, iid, *rewrite, "", ACTOR, reason))

    def status(iid, st, related=""):
        steps.append(_call(session, "MEM_ORG_SET_STATUS", topic, iid, st, reason, related, ACTOR))

    if kind == "activate":
        update(item_id)
        status(item_id, "active")
    elif kind == "duplicate":
        status(item_id, "merged", target)
    elif kind == "merge":
        update(target)
        status(item_id, "merged", target)
    elif kind == "supersede":
        update(item_id)
        status(item_id, "active")
        status(target, "superseded", item_id)
    elif kind == "reject":
        status(item_id, "rejected")
    else:
        status(item_id, "needs_review")
    failed = [s for s in steps if not (s or {}).get("ok")]
    return {"item": item_id, "decision": kind, "target": target if kind in ("duplicate", "merge", "supersede") else None, "reason": reason,
            "rewritten": any(rewrite), **({"failed_steps": failed} if failed else {})}


def organise(session, topic, trigger):
    cfg = _config(session, topic)
    if trigger == "insert":  # consume this topic's stream so the triggered task stops firing
        session.sql(f"INSERT INTO {FQ}.MEM_STREAM_SINK SELECT TOPIC_ID, ITEM_ID FROM {FQ}.{cfg['_names']['stream']} WHERE FALSE").collect()
    batch = int(cfg["organiser"]["on_insert"].get("batch_max", 20))
    pending = session.sql(f"SELECT * FROM {FQ}.MEM_ITEM WHERE TOPIC_ID = ? AND STATUS = 'new' "
                          f"ORDER BY CREATED_AT LIMIT {batch}", params=[topic]).collect()
    if not pending:
        return json.dumps({"topic": topic, "processed": 0})
    run_id = _start_run(session, topic, trigger, "pipeline")
    actions, errors = [], []
    for r in pending:
        try:
            nb = session.sql(
                f"""SELECT o.*, VECTOR_COSINE_SIMILARITY(o.EMBEDDING, n.EMBEDDING) AS SIM
                      FROM {FQ}.MEM_ITEM o JOIN {FQ}.MEM_ITEM n ON n.TOPIC_ID = o.TOPIC_ID AND n.ITEM_ID = ?
                     WHERE o.TOPIC_ID = ? AND o.ITEM_ID <> n.ITEM_ID AND o.STATUS IN ('active', 'new', 'needs_review')
                    QUALIFY ROW_NUMBER() OVER (ORDER BY SIM DESC) <= 6 OR o.ITEM_ID = n.SUPERSEDES
                     ORDER BY SIM DESC""",
                params=[r["ITEM_ID"], topic]).collect()
            neighbours = [_item_view(x, with_sim=True) for x in nb]
            d = _decide(session, cfg, _item_view(r), neighbours)
            actions.append(_apply(session, topic, r["ITEM_ID"], d, {x["ITEM_ID"] for x in nb}))
        except Exception as e:  # leave the item 'new' so the next run retries it
            errors.append(f"{r['ITEM_ID']}: {str(e)[:500]}")
    _finish_run(session, run_id, len(pending), actions, f"{len(actions)} decided", "; ".join(errors))
    return json.dumps({"topic": topic, "run_id": run_id, "processed": len(actions), "errors": errors,
                       "actions": actions}, default=_default)


def organise_handler(session, topic, trigger):
    return organise(session, topic, (trigger or "manual").lower())


def _agent_answer(raw):
    resp = _json(raw)
    if "content" not in resp:
        raise RuntimeError(resp.get("message") or str(raw)[:2000])
    texts, tools = [], []
    for part in resp["content"]:
        if part.get("type") == "text" and part.get("text", "").strip():
            texts.append(part["text"].strip())
        elif part.get("type") in ("tool_use", "tool_result"):
            texts = []
            name = (part.get("tool_use") or {}).get("name")
            if name:
                tools.append(name)
    return "\n\n".join(texts).strip(), tools


def review_handler(session, topic):
    cfg = _config(session, topic)
    triage = json.loads(organise(session, topic, "cadence"))
    windows = cfg["organiser"].get("review_after_days") or {}
    counts = {r["STATUS"]: r["N"] for r in session.sql(
        f"SELECT STATUS, COUNT(*) AS N FROM {FQ}.MEM_ITEM WHERE TOPIC_ID = ? GROUP BY 1", params=[topic]).collect()}
    needs = session.sql(f"SELECT ITEM_ID, TITLE, STATUS_REASON FROM {FQ}.MEM_ITEM WHERE TOPIC_ID = ? "
                        "AND STATUS IN ('needs_review', 'new') ORDER BY CREATED_AT", params=[topic]).collect()
    stale = []
    for cat, days in windows.items():
        stale += session.sql(
            f"SELECT ITEM_ID, TITLE, CATEGORY, AS_OF_DATE, UPDATED_AT FROM {FQ}.MEM_ITEM WHERE TOPIC_ID = ? "
            f"AND STATUS = 'active' AND CATEGORY = ? AND COALESCE(AS_OF_DATE, UPDATED_AT::DATE) < DATEADD(day, -{int(days)}, CURRENT_DATE())",
            params=[topic, cat]).collect()
    fmt = lambda rows, extra: "\n".join(f"- {r['ITEM_ID']}: {r['TITLE']}" + extra(r) for r in rows) or "- none"
    names = cfg["_names"]
    message = f"""Scheduled review of the '{cfg['topic']['name']}' memory ({date.today().isoformat()}).
Item counts by status: {json.dumps(counts)}.

Items that need your decision (status needs_review or new):
{fmt(needs, lambda r: f"  [flagged: {r['STATUS_REASON']}]" if r['STATUS_REASON'] else '')}

Active items past their review window:
{fmt(stale, lambda r: f"  ({r['CATEGORY']}, as_of {r['AS_OF_DATE']}, updated {str(r['UPDATED_AT'])[:10]})")}

Do, in order:
1. Resolve every item that needs a decision (activate, merge into another, supersede, reject), with a reason.
2. Read the index and list_items per category; merge items that state the same fact, fix misfiled categories,
   and rewrite titles that don't work as one index line.
3. Handle the stale items according to your instructions.
4. Write the overview with write_overview.
Finish with a short list of what you changed."""
    run_id = _start_run(session, topic, "cadence", "agent")
    answer, tools, error = "", [], ""
    try:
        body = {"messages": [{"role": "user", "content": [{"type": "text", "text": message}]}]}
        raw = session.sql("SELECT SNOWFLAKE.CORTEX.DATA_AGENT_RUN(?, ?)",
                          params=[f"{FQ}.{names['agent']}", json.dumps(body)]).collect()[0][0]
        answer, tools = _agent_answer(raw)
    except Exception as e:
        error = str(e)[:4000]
    _finish_run(session, run_id, len(needs) + len(stale), [{"tool": t} for t in tools], answer, error)
    return json.dumps({"topic": topic, "triage": triage, "review_run_id": run_id, "tools_used": len(tools),
                       "answer": answer, "error": error or None}, default=_default)
