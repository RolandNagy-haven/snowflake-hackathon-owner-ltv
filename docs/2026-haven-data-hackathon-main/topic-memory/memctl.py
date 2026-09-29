"""memctl: provision topic-memory topics (shared agent memory on Snowflake, one MCP server per topic).

    python topic-memory/memctl.py validate topics/footfall_bookings.yaml
    python topic-memory/memctl.py render   topics/footfall_bookings.yaml          # -> topic-memory/build/<topic>/*.sql
    python topic-memory/memctl.py deploy   topics/footfall_bookings.yaml [--only 30,50] [--skip-core] [--dry-run]
    python topic-memory/memctl.py status   [topic_id]
    python topic-memory/memctl.py organise footfall_bookings [--review]         # run the organiser now
    python topic-memory/memctl.py smoke    topics/footfall_bookings.yaml [--write]
    python topic-memory/memctl.py client   topics/footfall_bookings.yaml [--install] [--protocol]
    python topic-memory/memctl.py teardown topics/footfall_bookings.yaml [--purge]

Config paths are resolved relative to the working directory, then to topic-memory/.
The config (YAML, schema in schema/topic_config.schema.json) is rendered through the Jinja templates in
templates/core (shared tables + organiser, deployed with every topic, idempotent) and templates/topic.
The resolved config is stored in MEM_TOPIC so the organiser reads exactly what was deployed.
"""
import argparse
import copy
import hashlib
import json
import os
import re
import sys
from pathlib import Path

import jinja2
import jsonschema
import yaml

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
BUILD = HERE / "build"
ACCOUNT_HOST = os.environ.get("SF_ACCOUNT_HOST", "bd78472.eu-west-1.snowflakecomputing.com")
# Client entries use repo-root-relative paths (Claude Code is started from the repo root; see README).
PYTHON = ".venv/bin/python3"
EMBED_MODELS = ["snowflake-arctic-embed-l-v2.0", "snowflake-arctic-embed-l-v2.0-8k", "multilingual-e5-large",
                "voyage-multilingual-2", "nv-embed-qa-4"]
RESERVED = {"title", "body", "category", "tags", "as_of_date", "supersedes", "agent_type", "query", "ids",
            "text_filter", "include_unreviewed", "top_k"}
MAX_DESC = 2500  # Snowflake MCP tool description limit (spike S1)
MAX_TOOL_NAME = 64
UNCATEGORISED = "uncategorised"

DEFAULTS = {
    "contributors": {"open": True, "agent_types": {}},
    "schema": {"tags": {"open": True, "max": 6, "suggested": []}, "attributes": {}, "as_of_date": "optional",
               "limits": {"title_max": 120, "body_max": 3000},
               "pii_patterns": [r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"]},
    "tools": {"index": {}, "search": {}, "get": {}, "save": {}},
    "retrieval": {"embed_model": "snowflake-arctic-embed-l-v2.0", "top_k_default": 8, "top_k_max": 25,
                  "min_similarity": 0.35, "dup_threshold": 0.85, "search_floor": 0.2, "keyword_boost": 0.15},
    "toc": {"section_item_limit": 30, "show_unreviewed": True},
    "organiser": {"model": "claude-sonnet-5", "on_insert": {"enabled": True, "batch_max": 20},
                  "cadence": {"enabled": True, "schedule": "USING CRON 0 5 * * * UTC", "budget_seconds": 600},
                  "review_after_days": {}, "triage_prompt": "", "review_prompt": ""},
    "deployment": {"read_only_server": False, "log_reads": True, "usage_roles": []},
}


# --------------------------------------------------------------------------- config

def _merge(base, over):
    out = copy.deepcopy(base)
    for k, v in (over or {}).items():
        out[k] = _merge(out[k], v) if isinstance(v, dict) and isinstance(out.get(k), dict) else v
    return out


def resolve_path(p: str) -> Path:
    for cand in (Path(p), HERE / p):
        if cand.exists():
            return cand.resolve()
    sys.exit(f"config not found: {p}")


def load_raw(path: Path) -> dict:
    """YAML config; `extends: <file>` starts from another config (relative to this one) and overrides it."""
    raw = yaml.safe_load(path.read_text())
    base = raw.pop("extends", None)
    return _merge(load_raw((path.parent / base).resolve()), raw) if base else raw


def load_config(path: Path) -> dict:
    raw = load_raw(path)
    schema = json.loads((HERE / "schema/topic_config.schema.json").read_text())
    errors = sorted(jsonschema.Draft202012Validator(schema).iter_errors(raw), key=lambda e: list(e.path))
    if errors:
        sys.exit("config invalid:\n" + "\n".join(f"  {'.'.join(map(str, e.path)) or '<root>'}: {e.message}" for e in errors))
    cfg = _merge(DEFAULTS, raw)
    cfg["topic"].setdefault("item_noun_plural", cfg["topic"]["item_noun"] + "s")
    cfg["topic"].setdefault("version", 1)
    return cfg


def lint(cfg: dict, ctx: dict) -> list[str]:
    problems = []
    for a in cfg["schema"]["attributes"]:
        if a in RESERVED:
            problems.append(f"schema.attributes.{a}: name is reserved ({', '.join(sorted(RESERVED))})")
    for k, a in cfg["schema"]["attributes"].items():
        if a["type"] == "enum" and not a.get("values"):
            problems.append(f"schema.attributes.{k}: enum needs values")
    for key, tl in ctx["t"]["tools"].items():
        if len(tl["description"]) > MAX_DESC:
            problems.append(f"tools.{key}: rendered description is {len(tl['description'])} chars (max {MAX_DESC}); "
                            "shorten the brief or set tools.{key}.description")
        if len(tl["name"]) > MAX_TOOL_NAME:
            problems.append(f"tools.{key}.name longer than {MAX_TOOL_NAME}")
    names = [tl["name"] for tl in ctx["t"]["tools"].values()]
    if len(set(names)) != len(names):
        problems.append(f"tool names must be unique: {names}")
    blob = json.dumps(cfg)
    if "$$" in blob:
        problems.append("config text must not contain '$$' (used to quote procedure bodies)")
    for cat in (cfg["organiser"].get("review_after_days") or {}):
        if cat not in cfg["schema"]["categories"]:
            problems.append(f"organiser.review_after_days.{cat}: not a category")
    for p in cfg["schema"]["pii_patterns"]:
        try:
            re.compile(p)
        except re.error as e:
            problems.append(f"schema.pii_patterns: {p!r}: {e}")
    return problems


# --------------------------------------------------------------------------- context

def _param(name, sql_type, required, description, default=None):
    json_type = {"VARCHAR": "string", "NUMBER": "number", "BOOLEAN": "boolean"}[sql_type]
    if not required and default is None:
        default = "''" if sql_type == "VARCHAR" else "NULL"
    decl = f"{name.upper()} {sql_type}" + ("" if required else f" DEFAULT {default}")
    return {"name": name, "sql_type": sql_type, "json_type": json_type, "required": required,
            "description": description, "decl": decl}


def _join(items, sep="; "):
    return sep.join(items)


def build_context(cfg: dict) -> dict:
    tp, br, sc, dep, org = cfg["topic"], cfg["brief"], cfg["schema"], cfg["deployment"], cfg["organiser"]
    tid, noun, plural = tp["id"], tp["item_noun"], tp["item_noun_plural"]
    ID = tid.upper()
    P = f"MEM_{ID}"
    fq = f"{dep['database']}.{dep['schema']}"
    n = {"index": f"{P}_INDEX", "search": f"{P}_SEARCH", "get": f"{P}_GET", "save": f"{P}_SAVE",
         "seq": f"{P}_SEQ", "stream": f"{P}_STREAM", "organise_task": f"{P}_ORGANISE_TASK",
         "review_task": f"{P}_REVIEW_TASK", "agent": f"{P}_ORGANISER", "mcp": f"{ID}_MEMORY_MCP",
         "mcp_ro": f"{ID}_MEMORY_RO_MCP", "org_list": f"{P}_ORG_LIST", "org_update": f"{P}_ORG_UPDATE",
         "org_set_status": f"{P}_ORG_SET_STATUS", "org_link": f"{P}_ORG_LINK", "org_overview": f"{P}_ORG_WRITE_OVERVIEW"}
    tools_cfg = cfg["tools"]
    tn = {"index": tools_cfg["index"].get("name") or f"{plural}_index",
          "search": tools_cfg["search"].get("name") or f"search_{plural}",
          "get": tools_cfg["get"].get("name") or f"get_{plural}",
          "save": tools_cfg["save"].get("name") or f"record_{noun}"}

    # built-in fallback category: category is optional on save, the organiser assigns a real one later
    sc["categories"].setdefault(UNCATEGORISED, "Not categorised yet; the organiser assigns a category")
    categories = [{"key": k, "desc": v} for k, v in sc["categories"].items()]
    agent_types = [{"key": k, "desc": v} for k, v in cfg["contributors"]["agent_types"].items()]
    agent_type_example = agent_types[0]["key"] if agent_types else "claude_code"
    agent_type_hint = (f"Any value is accepted, e.g. {', '.join(a['key'] for a in agent_types)}." if agent_types
                       else "Any value is accepted.")
    tags = dict(sc["tags"])
    tags["suggested_sql"] = "ARRAY_CONSTRUCT(" + ", ".join(sqlstr(s) for s in tags["suggested"]) + ")"

    attributes = []
    for k, a in sc["attributes"].items():
        sql_type = {"number": "NUMBER", "boolean": "BOOLEAN"}.get(a["type"], "VARCHAR")
        value = {"list": f"IFF(ARRAY_SIZE(:attr_{k}) = 0, NULL, :attr_{k})",
                 "text": f"NULLIF(TRIM(:{k.upper()}), '')",
                 "enum": f"NULLIF(LOWER(TRIM(:{k.upper()})), '')"}.get(a["type"], f":{k.upper()}")
        desc = a["description"]
        if a["type"] == "enum":
            desc += f" One of: {', '.join(a['values'])}."
        if a["type"] == "list":
            desc += " (comma-separated)"
        attributes.append({**a, "name": k, "param": k.upper(), "sql_type": sql_type, "value_expr": value,
                           "short": re.split(r" e\.g\.|;", a["description"])[0][:90].rstrip(",. ").replace("'", ""), "required": bool(a.get("required")),
                           "param_desc": desc, "values": a.get("values", []), "max_len": a.get("max_len")})
    as_of_required = sc["as_of_date"] == "required"

    # ---- tool parameters (order: required first; Snowflake wants optional arguments last)
    cat_keys = ", ".join(c["key"] for c in categories)
    save_req = [
        _param("title", "VARCHAR", True, f"One index line (<= {sc['limits']['title_max']} chars) saying what this {noun} is about."),
        _param("body", "VARCHAR", True, f"The self-contained {noun} (<= {sc['limits']['body_max']} chars), written as the rules in the tool description say."),
        _param("agent_type", "VARCHAR", True, f"Your agent type (contributor identity), e.g. the client or agent name. {agent_type_hint}"),
    ] + [_param(a["name"], a["sql_type"], True, a["param_desc"]) for a in attributes if a["required"]]
    as_of_desc = f"Date the facts refer to, YYYY-MM-DD ({'required' if as_of_required else 'optional, but give it for numbers and time-bound facts'})."
    if as_of_required:
        save_req.append(_param("as_of_date", "VARCHAR", True, as_of_desc))
    save_opt = [
        _param("category", "VARCHAR", False, f"Optional, one of: {cat_keys}. Leave empty if unsure: it defaults to "
               f"{UNCATEGORISED} and the organiser assigns one."),
        _param("tags", "VARCHAR", False, f"Optional comma-separated tags (max {tags['max']})"
               + (f", e.g. {', '.join(tags['suggested'])}." if tags["suggested"] else ".")),
        _param("supersedes", "VARCHAR", False, f"Optional id of an existing {noun} that this one corrects or replaces (e.g. {tp['id_prefix']}-00012)."),
    ]
    if not as_of_required:
        save_opt.append(_param("as_of_date", "VARCHAR", False, as_of_desc))
    save_opt += [_param(a["name"], a["sql_type"], False, a["param_desc"]) for a in attributes if not a["required"]]
    save_params = save_req + save_opt

    ret = cfg["retrieval"]
    search_params = [
        _param("query", "VARCHAR", True, "What you want to know, as a question or topic."),
        _param("category", "VARCHAR", False, f"Optional: only this category ({cat_keys})."),
        _param("text_filter", "VARCHAR", False, "Optional exact text that must appear (e.g. a table or column name)."),
        _param("include_unreviewed", "BOOLEAN", False, "Include items not yet reviewed by the organiser (default true).", "TRUE"),
        _param("top_k", "NUMBER", False, f"Max results (default {ret['top_k_default']}, max {ret['top_k_max']}).", str(ret["top_k_default"])),
        _param("agent_type", "VARCHAR", False, "Optional: your agent type (for usage stats)."),
    ]
    get_params = [
        _param("ids", "VARCHAR", True, f"Comma-separated ids, e.g. {tp['id_prefix']}-00001,{tp['id_prefix']}-00007 (max 20)."),
        _param("agent_type", "VARCHAR", False, "Optional: your agent type (for usage stats)."),
    ]
    index_params = [
        _param("category", "VARCHAR", False, f"Optional: show one whole category ({cat_keys}) instead of the overview of all."),
        _param("since", "VARCHAR", False, f"Optional: only {plural} added or changed since then: the checked_at value from "
               f"an earlier call (YYYY-MM-DD HH24:MI:SS), or a duration like 30m, 2h, 1d."),
        _param("agent_type", "VARCHAR", False, "Optional: your agent type (for usage stats)."),
    ]

    # ---- tool descriptions (rendered from the brief unless overridden)
    extra = {k: (tools_cfg[k].get("extra") or "").strip() for k in tn}
    cats_long = _join(f"{c['key']} ({c['desc']})" for c in categories)
    # The memory changes in the background (other agents, the organiser), so every description says so and
    # tells the client when to look again; brief.usage lets a topic phrase it for its context (e.g. an event).
    live = (br.get("usage") or f"This memory is live: other agents add {plural} and an organiser merges, corrects and "
            f"supersedes them in the background, so check it again during your task, not only at the start.").strip()
    desc = {
        "index": (f"START HERE, and come back during your task. Opens the shared '{tp['name']}' memory: its brief, the "
                  f"rules for contributing, and an index of all {plural} (one line each with its id, grouped by "
                  f"category). {br['summary']} In scope: {br['scope']}\n{live}\n"
                  f"Call it at the start of any task in scope. Later, call it with since=<checked_at from your previous "
                  f"call> (or e.g. since=30m) to get only what was added or changed meanwhile. Use {tn['get']} for full "
                  f"text and {tn['search']} for a specific question. {extra['index']}"),
        "search": (f"Semantic search over the {plural} in the shared '{tp['name']}' memory. {br['summary']}\n{live}\n"
                   f"Search again for each new sub-question instead of relying on earlier results. Returns the best "
                   f"matches: id, title, category, short summary, as_of_date, relevance score, whether the organiser has "
                   f"reviewed it yet, and checked_at. Read full text with {tn['get']}. Filters: category, text_filter "
                   f"(exact text such as a table or column name). {extra['search']}"),
        "get": (f"Read full {plural} by id from the shared '{tp['name']}' memory: body, attributes "
                f"({', '.join(a['name'] for a in attributes) or 'none'}), status, contributor and links. {plural.capitalize()} "
                f"change in the background: re-read one before you rely on it later in your task. If it was merged or "
                f"superseded, replaced_by names the id to read instead. {extra['get']}"),
        "save": (f"Record ONE new {noun} in the shared '{tp['name']}' memory, which many agents read and write at the same "
                 f"time (scope: see {tn['index']}).\n"
                 f"Save when: {br['contribute_when']}\nHow to write: {br['how_to_write']}\nDo NOT save: {br['do_not_save']}\n"
                 f"Categories: {cats_long}.\n"
                 f"Call {tn['search']} right before saving: another agent may have recorded the same thing minutes ago. "
                 f"Returns the new id (status 'new': searchable at once, then reviewed by an organiser that may rewrite, "
                 f"merge or reject it) and the most similar existing {plural}. {extra['save']}"),
    }
    if len(desc["save"]) > MAX_DESC:  # fall back to category keys only
        desc["save"] = desc["save"].replace(f"Categories: {cats_long}.", f"Categories: {cat_keys} (see {tn['index']}).")
    tools = {}
    for k in tn:
        override = tools_cfg[k].get("description")
        tools[k] = {"name": tn[k],
                    "title": tools_cfg[k].get("title") or f"{tp['name']}: {k}",
                    "description": re.sub(r"[ \t]+", " ", (override or desc[k])).strip()}

    index_header = (
        f"# {tp['name']}: shared memory of {plural}\n{br['summary']}\n\nScope: {br['scope']}\n\n{live}\n\n"
        f"Contribute when: {br['contribute_when']}\nHow to write: {br['how_to_write']}\nDo not save: {br['do_not_save']}\n\n"
        f"Tools: {tn['index']} (this index; category=<c> shows a whole category; since=<checked_at> or since=30m shows "
        f"only what changed), {tn['search']} (semantic search), "
        f"{tn['get']} (full text by id), {tn['save']} (record one {noun}; always pass agent_type). {agent_type_hint}")

    organiser_instructions = (
        f"You are the organiser (curator) of the shared memory topic '{tp['name']}'. Agents of several types contribute "
        f"{plural}; you keep the collection correct, free of duplicates, well categorised and easy to scan. You only use "
        f"your tools; you never query business data.\n\n"
        f"The topic: {br['summary']}\nScope: {br['scope']}\nHow {plural} must be written: {br['how_to_write']}\n"
        f"Never keep: {br['do_not_save']}\nCategories: {cats_long}.\n\n"
        f"Rules:\n"
        f"- Never invent facts. When merging, keep every fact from both items in the survivor: update_item on the survivor, "
        f"then set_status merged on the other with related_id = the survivor.\n"
        f"- A correction or newer value: set_status superseded on the old item with related_id = the new one.\n"
        f"- Reject items that are out of scope, not durable, or contain personal data. Retire items that are no longer true.\n"
        f"- Every change needs a short reason: it is shown to readers and kept in the audit trail.\n"
        f"- Titles are index lines: specific, <= {sc['limits']['title_max']} chars, starting with the table or concept, "
        f"without dates (the index shows as_of_date next to each title).\n"
        f"- Check each tool result: ok=false means the change failed; read the error and fix the call.\n"
        f"- Pass agent_type='organiser' to index/search/get.\n\n"
        f"Topic review rules:\n{org.get('review_prompt') or '(none)'}")

    mcp_url = f"https://{ACCOUNT_HOST}/api/v2/databases/{dep['database']}/schemas/{dep['schema']}/mcp-servers/{n['mcp']}"
    t = {"id": tid, "ID": ID, "name": tp["name"], "noun": noun, "plural": plural, "prefix": tp["id_prefix"],
         "version": tp["version"], "limits": sc["limits"], "categories": categories, "agent_types": agent_types,
         "contributors_open": cfg["contributors"]["open"], "agent_type_example": agent_type_example,
         "as_of_required": as_of_required, "tags": tags, "attributes": attributes, "pii_patterns": sc["pii_patterns"],
         "retrieval": ret, "toc": cfg["toc"], "log_reads": dep["log_reads"], "tools": tools,
         "index_header": index_header, "warehouse": dep["warehouse"], "read_only_server": dep["read_only_server"],
         "mcp_url": mcp_url, "mcp_ro_url": mcp_url.replace(n["mcp"], n["mcp_ro"]), "organiser": org,
         "organiser_instructions": organiser_instructions, "usage_roles": dep["usage_roles"]}

    def sig(proc, params):
        return f"{proc}({', '.join(p['sql_type'] for p in params)})"
    contributor = [sig(n["index"], index_params), sig(n["search"], search_params), sig(n["get"], get_params),
                   sig(n["save"], save_params)]
    organiser = [f"{n['org_list']}(VARCHAR, VARCHAR, NUMBER)", f"{n['org_update']}(VARCHAR, VARCHAR, VARCHAR, VARCHAR, VARCHAR, VARCHAR, VARCHAR)",
                 f"{n['org_set_status']}(VARCHAR, VARCHAR, VARCHAR, VARCHAR)", f"{n['org_link']}(VARCHAR, VARCHAR, VARCHAR, VARCHAR)",
                 f"{n['org_overview']}(VARCHAR)"]

    stored = copy.deepcopy(cfg)
    stored["_names"] = n
    stored["_tools"] = {k: v["name"] for k, v in tools.items()}
    return {"cfg": cfg, "stored": stored, "t": t, "n": n, "fq": fq, "embed_models": EMBED_MODELS,
            "save_params": save_params, "search_params": search_params, "get_params": get_params,
            "index_params": index_params, "list_attrs": [a for a in attributes if a["type"] == "list"],
            "params": {"index": index_params, "search": search_params, "get": get_params, "save": save_params},
            "signatures": {"contributor": contributor, "all": contributor + organiser}, "purge": False}


# --------------------------------------------------------------------------- rendering

def sqlstr(s) -> str:
    return "'" + str(s).replace("\\", "\\\\").replace("'", "''").replace("\n", "\\n") + "'"


class _Env(jinja2.Environment):
    """`x.get` on a dict must mean the key 'get', not dict.get (tool keys are index/search/get/save)."""

    def getattr(self, obj, attribute):
        if isinstance(obj, dict) and attribute in obj:
            return obj[attribute]
        return super().getattr(obj, attribute)


def _env() -> jinja2.Environment:
    env = _Env(loader=jinja2.FileSystemLoader(str(HERE / "templates")),
                             undefined=jinja2.StrictUndefined, keep_trailing_newline=True)
    env.filters["sqlstr"] = sqlstr
    env.filters["tojson"] = lambda v: json.dumps(v, ensure_ascii=False)
    return env


def render(ctx: dict, only: list[str] | None = None, teardown=False) -> list[tuple[str, str]]:
    env = _env()
    names = ([f"topic/99_teardown.sql.j2"] if teardown else
             [f"core/{p.name}" for p in sorted((HERE / "templates/core").glob("*.sql.j2"))]
             + [f"topic/{p.name}" for p in sorted((HERE / "templates/topic").glob("*.sql.j2")) if not p.name.startswith("99_")])
    out = []
    for name in names:
        short = name.split("/")[1].replace(".sql.j2", "")
        if only and not any(short.startswith(o) or name.startswith(o) for o in only):
            continue
        out.append((name.replace(".j2", ""), env.get_template(name).render(**ctx)))
    return out


def has_statements(sql: str) -> bool:
    return any(line.strip() and not line.strip().startswith("--") for line in sql.splitlines())


# --------------------------------------------------------------------------- snowflake

def session(cfg: dict | None = None):
    """Snowpark session; with a config, switches to its deployment role (primary role: it owns what we create)
    and warehouse."""
    sys.path.insert(0, str(ROOT / ".claude/skills/snowflake-query"))
    from snowflake_session import get_or_create_session
    dep = (cfg or {}).get("deployment", {})
    sess = get_or_create_session(role=dep.get("role"))
    if dep.get("warehouse"):
        sess.sql(f"USE WAREHOUSE {dep['warehouse']}").collect()
    return sess


def resolve_topic(arg: str) -> tuple[str, str, dict | None]:
    """A config path -> (fq, topic id, cfg); a bare topic id -> the default dev schema."""
    if arg.endswith((".yaml", ".yml")):
        cfg = load_config(resolve_path(arg))
        return f"{cfg['deployment']['database']}.{cfg['deployment']['schema']}", cfg["topic"]["id"], cfg
    return os.environ.get("MEM_FQ", "HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL"), arg, None


def execute(sess, name: str, sql: str) -> None:
    print(f"== {name}")
    for cur in sess._conn._conn.execute_string(sql, remove_comments=False):
        row = cur.fetchone()
        print(f"   {cur.sfqid}  {str(row[0] if row else '')[:110]}")


def register(sess, ctx: dict) -> None:
    stored, n, t = ctx["stored"], ctx["n"], ctx["t"]
    blob = json.dumps(stored, sort_keys=True)
    sess.sql(f"""
        MERGE INTO {ctx['fq']}.MEM_TOPIC d
        USING (SELECT ? AS TOPIC_ID, ? AS NAME, ? AS VERSION, PARSE_JSON(?) AS CONFIG, ? AS CONFIG_HASH,
                      ? AS OBJECT_PREFIX, ? AS MCP_SERVER, ? AS ORGANISER_AGENT) s
           ON d.TOPIC_ID = s.TOPIC_ID
        WHEN MATCHED THEN UPDATE SET NAME = s.NAME, VERSION = s.VERSION, CONFIG = s.CONFIG, CONFIG_HASH = s.CONFIG_HASH,
             OBJECT_PREFIX = s.OBJECT_PREFIX, MCP_SERVER = s.MCP_SERVER, ORGANISER_AGENT = s.ORGANISER_AGENT,
             DEPLOYED_AT = CURRENT_TIMESTAMP(), DEPLOYED_BY = CURRENT_USER()
        WHEN NOT MATCHED THEN INSERT (TOPIC_ID, NAME, VERSION, CONFIG, CONFIG_HASH, OBJECT_PREFIX, MCP_SERVER, ORGANISER_AGENT)
             VALUES (s.TOPIC_ID, s.NAME, s.VERSION, s.CONFIG, s.CONFIG_HASH, s.OBJECT_PREFIX, s.MCP_SERVER, s.ORGANISER_AGENT)""",
             params=[t["id"], t["name"], t["version"], blob, hashlib.sha256(blob.encode()).hexdigest()[:16],
                     f"MEM_{t['ID']}", f"{ctx['fq']}.{n['mcp']}", f"{ctx['fq']}.{n['agent']}"]).collect()
    print(f"== registered {t['id']} v{t['version']} in {ctx['fq']}.MEM_TOPIC")


# --------------------------------------------------------------------------- commands

def cmd_validate(a):
    cfg = load_config(resolve_path(a.config))
    ctx = build_context(cfg)
    problems = lint(cfg, ctx)
    for k, tl in ctx["t"]["tools"].items():
        print(f"  tool {tl['name']:24s} description {len(tl['description']):4d}/{MAX_DESC} chars, "
              f"{len(ctx['params'][k])} params")
    if problems:
        sys.exit("lint problems:\n" + "\n".join(f"  - {p}" for p in problems))
    print(f"{cfg['topic']['id']}: OK")
    return ctx


def cmd_render(a):
    ctx = cmd_validate(a)
    out_dir = BUILD / f"{ctx['cfg']['deployment']['schema'].lower()}__{ctx['t']['id']}"
    out_dir.mkdir(parents=True, exist_ok=True)
    for name, sql in render(ctx, a.only):
        (out_dir / name.replace("/", "_")).write_text(sql)
    ctx2 = dict(ctx, purge=getattr(a, "purge", False))
    (out_dir / "topic_99_teardown.sql").write_text(render(ctx2, teardown=True)[0][1])
    print(f"rendered to {out_dir}")


def cmd_deploy(a):
    ctx = cmd_validate(a)
    files = render(ctx, a.only)
    if a.skip_core:
        files = [f for f in files if not f[0].startswith("core/")]
    if a.dry_run:
        for name, sql in files:
            print(f"\n-- ==== {name}\n{sql}")
        return
    sess = session(ctx["cfg"])
    dep = ctx["cfg"]["deployment"]
    if dep.get("create_schema"):
        execute(sess, "create schema", f"CREATE SCHEMA IF NOT EXISTS {ctx['fq']};")
    registered = False
    for name, sql in files:
        if name.startswith("topic/") and not registered:
            register(sess, ctx)
            registered = True
        if has_statements(sql):
            execute(sess, name, sql)
    if not registered:
        register(sess, ctx)
    print(f"\nMCP server: {ctx['fq']}.{ctx['n']['mcp']}\n  {ctx['t']['mcp_url']}")
    if ctx["t"]["read_only_server"]:
        print(f"read-only:  {ctx['t']['mcp_ro_url']}")
    print(f"next: python topic-memory/memctl.py smoke {a.config} --write ; python topic-memory/memctl.py client {a.config} --install")


def cmd_status(a):
    fq, topic, cfg = resolve_topic(a.topic) if a.topic else (os.environ.get("MEM_FQ", "HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL"), None, None)
    sess = session(cfg)
    where = f"WHERE TOPIC_ID = '{topic}'" if topic else ""
    for r in sess.sql(f"SELECT * FROM {fq}.MEM_V_TOPIC_STATS {where} ORDER BY TOPIC_ID").collect():
        print(json.dumps(r.as_dict(), default=str, indent=1))
    for r in sess.sql(f"SELECT RUN_ID, TOPIC_ID, TRIGGER_KIND, ENGINE, STARTED_AT, FINISHED_AT, ITEMS_IN, "
                      f"LEFT(RESULT, 300) AS RESULT, LEFT(ERROR, 300) AS ERROR FROM {fq}.MEM_ORGANISER_RUN {where} "
                      f"ORDER BY STARTED_AT DESC LIMIT 5").collect():
        d = r.as_dict()
        print(f"  run {d['RUN_ID']} {d['TOPIC_ID']} {d['TRIGGER_KIND']}/{d['ENGINE']} {str(d['STARTED_AT'])[:19]} "
              f"items={d['ITEMS_IN']} result={d['RESULT']!r} error={d['ERROR']!r}")


def cmd_organise(a):
    fq, topic, cfg = resolve_topic(a.topic)
    sess = session(cfg)
    if a.review:
        out = sess.call(f"{fq}.MEM_REVIEW", topic)
    else:
        out = sess.call(f"{fq}.MEM_ORGANISE", topic, "manual")
    print(json.dumps(json.loads(out), indent=1))


def cmd_smoke(a):
    ctx = cmd_validate(a)
    if ctx["cfg"]["deployment"].get("client_role"):  # read by sf_mcp_auth at import
        os.environ["SF_ROLE"] = ctx["cfg"]["deployment"]["client_role"]
    sys.path.insert(0, str(HERE))
    from mcp_http import McpClient
    t, tn = ctx["t"], {k: v["name"] for k, v in ctx["t"]["tools"].items()}
    c = McpClient(t["mcp_url"])
    tools = c.list_tools()
    print("tools/list:", [x["name"] for x in tools])
    text, err, dt = c.call(tn["index"], {"agent_type": "smoke_test"})
    print(f"\n{tn['index']} ({dt}s, error={err}):\n{text[:1500]}")
    text, err, dt = c.call(tn["search"], {"query": "table grain", "agent_type": "smoke_test"})
    print(f"\n{tn['search']} ({dt}s, error={err}):\n{text[:800]}")
    if a.write:
        args = {"title": "SMOKE TEST - ignore", "body": "Smoke test item written by memctl smoke; it is rejected immediately.",
                "category": t["categories"][0]["key"], "agent_type": "smoke_test"}
        for attr in t["attributes"]:
            if attr["required"]:
                args[attr["name"]] = attr["values"][0] if attr["type"] == "enum" else (1 if attr["sql_type"] == "NUMBER" else "SMOKE.TEST")
        bad, err, dt = c.call(tn["save"], {**args, "category": "no_such_category"})
        print(f"\n{tn['save']} invalid ({dt}s, error={err}):\n{bad[:600]}")
        text, err, dt = c.call(tn["save"], args)
        print(f"\n{tn['save']} ({dt}s, error={err}):\n{text[:800]}")
        new_id = json.loads(text).get("id")
        text, err, dt = c.call(tn["get"], {"ids": new_id})
        print(f"\n{tn['get']} ({dt}s, error={err}):\n{text[:600]}")
        sess = session(ctx["cfg"])
        sess.call(f"{ctx['fq']}.MEM_ORG_SET_STATUS", t["id"], new_id, "rejected", "smoke test item", "", "memctl:smoke")
        print(f"\nrejected {new_id}")


def _protocol(ctx) -> str:
    t, tn = ctx["t"], {k: v["name"] for k, v in ctx["t"]["tools"].items()}
    br = ctx["cfg"]["brief"]
    return f"""## Shared memory: {t['name']} (MCP server `{ctx['n']['mcp']}`)
Several agents share this memory and it changes while you work. Scope: {br['scope']}
{br.get('usage') or ''}
- At the start of a task in scope, call `{tn['index']}` (brief, rules, index of all {t['plural']}), then
  `{tn['get']}` for the ids that matter. Keep the `checked_at` it returns.
- Check again during the task: `{tn['search']}` before each new sub-question, before expensive queries, and before
  stating a number or definition; `{tn['index']}` with `since=<checked_at>` to see what others added meanwhile.
- Before exploring the data yourself, check whether a {t['noun']} already answers it.
- After verified work, search once more, then record at most 2-3 durable {t['plural']} with `{tn['save']}`,
  following the rules in the index. Always pass `agent_type` (e.g. `{t['agent_type_example']}`). If a {t['noun']}
  you used was wrong, record the corrected one with `supersedes=<id>`.
- Items marked [unreviewed] are new; use them, but verify numbers that matter.
"""


def cmd_client(a):
    ctx = cmd_validate(a)
    t, n = ctx["t"], ctx["n"]
    # stdio proxy, not a plain http entry: Snowflake answers an expired session (1 h) with HTTP 200 + a REST error
    # body, so Claude Code never re-runs a headersHelper; the proxy logs in again and retries (see sf_mcp_proxy.py).
    proxy = "invocation-poc/sf_mcp_proxy.py"
    dep = ctx["cfg"]["deployment"]
    key = dep.get("client_name") or f"mem-{t['id'].replace('_', '-')}"
    env = {"env": {"SF_ROLE": dep["client_role"]}} if dep.get("client_role") else {}
    entries = {key: {"type": "stdio", "command": PYTHON, "args": [proxy, t["mcp_url"]], **env}}
    if t["read_only_server"]:
        entries[key + "-ro"] = {"type": "stdio", "command": PYTHON, "args": [proxy, t["mcp_ro_url"]], **env}
    # hooks get $CLAUDE_PROJECT_DIR (MCP config does not), so the hook works from any directory
    role = f"SF_ROLE={dep['client_role']} " if dep.get("client_role") else ""
    hook_cmd = (f'{role}"$CLAUDE_PROJECT_DIR"/{PYTHON} "$CLAUDE_PROJECT_DIR"/topic-memory/hooks/session_start_index.py '
                f"{t['mcp_url']} {t['tools']['index']['name']} claude_code {key}")
    print("# .mcp.json entries\n" + json.dumps({"mcpServers": entries}, indent=2))
    print("\n# Optional SessionStart hook (loads the index into every session, like MEMORY.md):")
    print(json.dumps({"hooks": {"SessionStart": [{"hooks": [{"type": "command", "command": hook_cmd, "timeout": 30}]}]}}, indent=2))
    if a.protocol:
        print("\n# Protocol snippet for CLAUDE.md / agent instructions\n" + _protocol(ctx))
    if a.install:
        path = ROOT / ".mcp.json"
        data = json.loads(path.read_text()) if path.exists() else {"mcpServers": {}}
        data.setdefault("mcpServers", {}).update({key: entries[key]})  # read-write server only
        path.write_text(json.dumps(data, indent=2) + "\n")
        print(f"\ninstalled '{key}' into {path} (restart Claude Code / run /mcp to connect)")


def cmd_teardown(a):
    cfg = load_config(resolve_path(a.config))
    ctx = dict(build_context(cfg), purge=a.purge)
    name, sql = render(ctx, teardown=True)[0]
    if a.dry_run:
        print(sql)
        return
    execute(session(cfg), name, sql)


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    for name in ("validate", "render", "deploy", "smoke", "client", "teardown"):
        s = sub.add_parser(name)
        s.add_argument("config")
        if name in ("render", "deploy"):
            s.add_argument("--only", nargs="*", help="template prefixes, e.g. 30 50 core/")
        if name == "deploy":
            s.add_argument("--skip-core", action="store_true")
            s.add_argument("--dry-run", action="store_true")
        if name == "smoke":
            s.add_argument("--write", action="store_true", help="also save / get one test item (then rejects it)")
        if name == "client":
            s.add_argument("--install", action="store_true", help="add the server to the repo .mcp.json")
            s.add_argument("--protocol", action="store_true", help="print a usage snippet for agent instructions")
        if name == "teardown":
            s.add_argument("--purge", action="store_true", help="also delete the topic's data")
            s.add_argument("--dry-run", action="store_true")
    s = sub.add_parser("status")
    s.add_argument("topic", nargs="?")
    s = sub.add_parser("organise")
    s.add_argument("topic")
    s.add_argument("--review", action="store_true", help="scheduled-review mode: triage, then the organiser agent")
    a = p.parse_args()
    {"validate": cmd_validate, "render": cmd_render, "deploy": cmd_deploy, "status": cmd_status,
     "organise": cmd_organise, "smoke": cmd_smoke, "client": cmd_client, "teardown": cmd_teardown}[a.cmd](a)


if __name__ == "__main__":
    main()
