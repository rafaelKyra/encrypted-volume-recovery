#!/usr/bin/env python3
"""Validate a Claude Code plugin against the published reference.

Stands in for `claude plugin validate` where the CLI is not installed. Checks
the manifest schema, every frontmatter block, the hooks schema, and this
plugin's own evidence rules (provenance headers on reference excerpts).

    python3 scripts/validate_plugin.py [plugin-dir]

Exits non-zero on any error. Warnings do not fail unless --strict.
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

# From https://code.claude.com/docs/en/plugins-reference
MANIFEST_KNOWN = {
    "name", "displayName", "version", "description", "author", "homepage",
    "repository", "license", "keywords", "metadata", "skills", "commands",
    "agents", "workflows", "hooks", "mcpServers", "outputStyles", "lspServers",
    "userConfig", "channels", "dependencies", "defaultEnabled", "experimental",
}
SKILL_KNOWN = {"name", "description", "disable-model-invocation",
               "allowed-tools", "argument-hint", "model"}
AGENT_KNOWN = {"name", "description", "model", "effort", "maxTurns", "tools",
               "disallowedTools", "skills", "memory", "background", "isolation"}
AGENT_FORBIDDEN = {"hooks", "mcpServers", "permissionMode"}   # security
HOOK_EVENTS = {
    "SessionStart", "Setup", "UserPromptSubmit", "UserPromptExpansion",
    "PreToolUse", "PermissionRequest", "PermissionDenied", "PostToolUse",
    "PostToolUseFailure", "PostToolBatch", "Notification", "MessageDisplay",
    "SubagentStart", "SubagentStop", "TaskCreated", "TaskCompleted", "Stop",
    "StopFailure", "TeammateIdle", "InstructionsLoaded", "ConfigChange",
    "CwdChanged", "DirectoryAdded", "FileChanged", "WorktreeCreate",
    "WorktreeRemove", "PreCompact", "PostCompact", "Elicitation",
    "ElicitationResult", "SessionEnd",
}
HOOK_TYPES = {"command", "http", "mcp_tool", "prompt", "agent"}
KEBAB = re.compile(r"^[a-z0-9]+(-[a-z0-9]+)*$")

errors: list[str] = []
warnings: list[str] = []


def err(msg: str) -> None:
    errors.append(msg)


def warn(msg: str) -> None:
    warnings.append(msg)


def frontmatter(path: Path) -> dict | None:
    """Parse the leading --- block. Minimal by design: no YAML dependency."""
    text = path.read_text(encoding="utf-8")
    if not text.startswith("---"):
        err(f"{path}: no frontmatter block")
        return None
    end = text.find("\n---", 3)
    if end == -1:
        err(f"{path}: frontmatter block is not closed")
        return None
    out: dict[str, object] = {}
    key = None
    for raw in text[3:end].splitlines():
        if not raw.strip() or raw.lstrip().startswith("#"):
            continue
        if raw.startswith((" ", "\t")) and key:          # continuation
            out[key] = f"{out[key]} {raw.strip()}"
            continue
        if ":" not in raw:
            err(f"{path}: cannot parse frontmatter line: {raw!r}")
            continue
        key, value = raw.split(":", 1)
        key, value = key.strip(), value.strip()
        if value.startswith("[") and value.endswith("]"):
            out[key] = [v.strip() for v in value[1:-1].split(",") if v.strip()]
        else:
            out[key] = value
    return out


def check_manifest(root: Path) -> str:
    path = root / ".claude-plugin" / "plugin.json"
    if not path.exists():
        err("missing .claude-plugin/plugin.json")
        return ""
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        err(f"plugin.json is not valid JSON: {exc}")
        return ""
    name = data.get("name", "")
    if not name:
        err("plugin.json: 'name' is required")
    elif not KEBAB.match(name):
        err(f"plugin.json: name {name!r} must be kebab-case")
    for key in data:
        if key not in MANIFEST_KNOWN:
            warn(f"plugin.json: unknown field {key!r}")
    if "version" in data and not re.match(r"^\d+\.\d+\.\d+", str(data["version"])):
        warn(f"plugin.json: version {data['version']!r} is not semver")
    author = data.get("author")
    if isinstance(author, dict) and "name" not in author:
        warn("plugin.json: author object has no 'name'")
    return name


def check_layout(root: Path) -> None:
    inside = root / ".claude-plugin"
    for bad in ("skills", "commands", "agents", "hooks"):
        if (inside / bad).exists():
            err(f".claude-plugin/{bad}/ must live at the plugin root, not inside "
                f".claude-plugin/")


def check_skills(root: Path) -> int:
    d = root / "skills"
    if not d.is_dir():
        warn("no skills/ directory")
        return 0
    count = 0
    for sub in sorted(p for p in d.iterdir() if p.is_dir()):
        f = sub / "SKILL.md"
        if not f.exists():
            err(f"{sub}: no SKILL.md")
            continue
        fm = frontmatter(f)
        if fm is None:
            continue
        count += 1
        name = fm.get("name")
        if not name:
            warn(f"{f}: no 'name' (falls back to the directory name)")
        elif name != sub.name:
            err(f"{f}: name {name!r} does not match directory {sub.name!r}")
        elif not KEBAB.match(str(name)):
            err(f"{f}: name {name!r} must be kebab-case")
        desc = str(fm.get("description", ""))
        if not desc:
            err(f"{f}: 'description' is required for model invocation")
        elif len(desc) < 40:
            warn(f"{f}: description is very short; add trigger phrases")
        elif "use when" not in desc.lower():
            warn(f"{f}: description has no 'Use when ...' trigger phrases")
        for key in fm:
            if key not in SKILL_KNOWN:
                warn(f"{f}: unknown frontmatter field {key!r}")
        body = f.read_text(encoding="utf-8")
        for heading in ("## When to use", "## Recipe", "## Pitfalls",
                        "## Verification"):
            if heading not in body:
                warn(f"{f}: merge contract wants a '{heading}' section")
    return count


def check_commands(root: Path) -> int:
    d = root / "commands"
    if not d.is_dir():
        return 0
    count = 0
    for f in sorted(d.glob("*.md")):
        fm = frontmatter(f)
        if fm is None:
            continue
        count += 1
        name = fm.get("name")
        if name and name != f.stem:
            err(f"{f}: name {name!r} does not match file name {f.stem!r}")
        if name and not KEBAB.match(str(name)):
            err(f"{f}: name {name!r} must be kebab-case")
        if not fm.get("description"):
            err(f"{f}: 'description' is required")
        for key in fm:
            if key not in SKILL_KNOWN:
                warn(f"{f}: unknown frontmatter field {key!r}")
    return count


def check_agents(root: Path, plugin: str, skills: set[str]) -> int:
    d = root / "agents"
    if not d.is_dir():
        return 0
    count = 0
    for f in sorted(d.glob("*.md")):
        fm = frontmatter(f)
        if fm is None:
            continue
        count += 1
        name = fm.get("name")
        if not name:
            err(f"{f}: 'name' is required")
        elif name != f.stem:
            err(f"{f}: name {name!r} does not match file name {f.stem!r}")
        if not fm.get("description"):
            err(f"{f}: 'description' is required")
        for key in fm:
            if key in AGENT_FORBIDDEN:
                err(f"{f}: plugin agents may not declare {key!r}")
            elif key not in AGENT_KNOWN:
                warn(f"{f}: unknown frontmatter field {key!r}")
        if "tools" in fm and not isinstance(fm["tools"], list):
            err(f"{f}: 'tools' must be an array")
        for ref in fm.get("skills", []) or []:
            if ":" not in ref:
                err(f"{f}: skill {ref!r} must be fully qualified as plugin:skill")
                continue
            owner, skill = ref.split(":", 1)
            if owner == plugin and skill not in skills:
                err(f"{f}: references unknown skill {ref!r}")
    return count


def check_hooks(root: Path) -> int:
    path = root / "hooks" / "hooks.json"
    if not path.exists():
        return 0
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        err(f"hooks.json is not valid JSON: {exc}")
        return 0
    total = 0
    events = data.get("hooks")
    if not isinstance(events, dict):
        err("hooks.json: top level must be an object with a 'hooks' key")
        return 0
    for event, entries in events.items():
        if event not in HOOK_EVENTS:
            err(f"hooks.json: unknown event {event!r}")
        for entry in entries:
            for hook in entry.get("hooks", []):
                total += 1
                kind = hook.get("type")
                if kind not in HOOK_TYPES:
                    err(f"hooks.json: unknown hook type {kind!r}")
                if kind == "command":
                    cmd = hook.get("command", "")
                    if not cmd:
                        err("hooks.json: command hook has no command")
                    ref = cmd.replace('"', "").replace("${CLAUDE_PLUGIN_ROOT}", str(root))
                    script = ref.split()[0] if ref else ""
                    if script and Path(script).suffix and not Path(script).exists():
                        err(f"hooks.json: command script not found: {script}")
                    elif script and Path(script).exists():
                        import os
                        if not os.access(script, os.X_OK):
                            err(f"hooks.json: script is not executable: {script}")
    return total


def check_references(root: Path) -> int:
    d = root / "references"
    if not d.is_dir():
        warn("no references/ directory")
        return 0
    for required in ("DECISIONS.md", "PITFALLS.md"):
        if not (d / required).exists():
            err(f"references/{required} is required by the merge contract")
    count = 0
    # Any language: the evidence rule is about provenance, not extension.
    # Any language, plus markdown excerpts (agent and command definitions are
    # markdown). DECISIONS.md and PITFALLS.md are the contract's own documents,
    # not excerpts, so they are excluded from the provenance requirement.
    _DOCS = {"DECISIONS.md", "PITFALLS.md"}
    excerpts = sorted(f for f in d.iterdir()
                      if f.is_file() and f.name not in _DOCS
                      and f.suffix in {".py", ".sh", ".rs", ".ts", ".go",
                                       ".dart", ".kts", ".kt", ".sql", ".md",
                                       ".yml", ".yaml", ".example"})
    for f in excerpts:
        count += 1
        head = f.read_text(encoding="utf-8")[:1200]
        if "PROVENANCE" not in head:
            err(f"{f}: no PROVENANCE header (evidence rule)")
        elif "Source:" not in head and "Palettes:" not in head:
            warn(f"{f}: provenance header names no source path")
    return count


def main() -> int:
    root = Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()
    strict = "--strict" in sys.argv
    print(f"Validating {root}\n")

    plugin = check_manifest(root)
    check_layout(root)
    n_skills = check_skills(root)
    skill_names = {p.name for p in (root / "skills").iterdir() if p.is_dir()} \
        if (root / "skills").is_dir() else set()
    n_cmds = check_commands(root)
    n_agents = check_agents(root, plugin, skill_names)
    n_hooks = check_hooks(root)
    n_refs = check_references(root)

    # Compile every reference excerpt: "runnable" is a claim worth checking.
    for f in sorted((root / "references").glob("*.py")):
        try:
            compile(f.read_text(encoding="utf-8"), str(f), "exec")
        except SyntaxError as exc:
            err(f"{f}: does not compile — line {exc.lineno}: {exc.msg}")

    print(f"  skills     {n_skills}")
    print(f"  commands   {n_cmds}")
    print(f"  agents     {n_agents}")
    print(f"  hooks      {n_hooks}")
    print(f"  references {n_refs} excerpts + DECISIONS.md + PITFALLS.md")
    print()

    for w in warnings:
        print(f"  warning: {w}")
    for e in errors:
        print(f"  ERROR:   {e}")
    print()

    if errors:
        print(f"✗ Validation failed: {len(errors)} error(s), {len(warnings)} warning(s)")
        return 1
    if warnings and strict:
        print(f"✗ Validation failed (--strict): {len(warnings)} warning(s)")
        return 1
    if warnings:
        print(f"✔ Validation passed with warnings ({len(warnings)})")
        return 0
    print("✔ Validation passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
