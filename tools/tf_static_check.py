#!/usr/bin/env python3
"""
Offline sanity checks for the Terraform in this repo, for machines that do not
have terraform installed. It is NOT a replacement for `terraform validate`
(CI runs the real thing). It catches the mistakes that cost the most time:

  * every .tf file parses as HCL2
  * every var.X / local.X reference is declared
  * every aws_x.y / data.x.y reference points at a declared resource or data source
  * every module.m.output reference is a declared output of that module
  * every module call passes only declared variables and all required ones

Usage:  python3 tools/tf_static_check.py terraform
"""
import json
import re
import sys
from pathlib import Path

import hcl2

COMMENT = re.compile(r"(^|\s)(#|//).*?$", re.M)
BLOCKCOMMENT = re.compile(r"/\*.*?\*/", re.S)


def unq(name: str) -> str:
    """python-hcl2 keeps the quotes around block labels; drop them."""
    return name.strip('"')


def load(directory: Path):
    """Parse every .tf file in one directory (non-recursive)."""
    merged = {"variable": {}, "locals": set(), "resource": set(), "data": set(), "output": set(), "module": {}}
    text = ""
    for f in sorted(directory.glob("*.tf")):
        raw = f.read_text()
        try:
            doc = hcl2.loads(raw)
        except Exception as exc:  # noqa: BLE001
            print(f"PARSE ERROR {f}: {exc}")
            sys.exit(2)
        text += BLOCKCOMMENT.sub("", COMMENT.sub("", raw)) + "\n"
        for v in doc.get("variable", []):
            for name, body in v.items():
                merged["variable"][unq(name)] = "default" in body
        for loc in doc.get("locals", []):
            merged["locals"].update(loc.keys())
        for r in doc.get("resource", []):
            for rtype, insts in r.items():
                for name in insts:
                    merged["resource"].add(f"{unq(rtype)}.{unq(name)}")
        for d in doc.get("data", []):
            for dtype, insts in d.items():
                for name in insts:
                    merged["data"].add(f"{unq(dtype)}.{unq(name)}")
        for o in doc.get("output", []):
            merged["output"].update(unq(k) for k in o.keys())
        for m in doc.get("module", []):
            for name, body in m.items():
                merged["module"][unq(name)] = body
    return merged, text


def check_dir(directory: Path, registry: dict) -> int:
    errors = 0
    info, text = registry[directory]
    # strip string literals' contents that are not interpolations is overkill;
    # references inside "${...}" are real references and must resolve too.
    for m in re.finditer(r"\bvar\.(\w+)", text):
        if m.group(1) not in info["variable"]:
            print(f"{directory}: undeclared variable var.{m.group(1)}")
            errors += 1
    for m in re.finditer(r"\blocal\.(\w+)", text):
        if m.group(1) not in info["locals"]:
            print(f"{directory}: undeclared local local.{m.group(1)}")
            errors += 1
    for m in re.finditer(r"\bdata\.(\w+)\.(\w+)", text):
        if f"{m.group(1)}.{m.group(2)}" not in info["data"]:
            print(f"{directory}: undeclared data source data.{m.group(1)}.{m.group(2)}")
            errors += 1
    for m in re.finditer(r"(?<![\w.])(aws_\w+|terraform_data|archive_file)\.(\w+)", text):
        if f"{m.group(1)}.{m.group(2)}" not in info["resource"]:
            # `aws_region.current` style appears only after data.; those are skipped by lookbehind.
            print(f"{directory}: reference to undeclared resource {m.group(1)}.{m.group(2)}")
            errors += 1
    for m in re.finditer(r"\bmodule\.(\w+)\.(\w+)", text):
        name, out = m.group(1), m.group(2)
        if name not in info["module"]:
            print(f"{directory}: reference to undeclared module.{name}")
            errors += 1
            continue
        src = (directory / unq(info["module"][name]["source"])).resolve()
        if src in registry and out not in registry[src][0]["output"]:
            print(f"{directory}: module.{name} has no output '{out}'")
            errors += 1
    for name, body in info["module"].items():
        src = (directory / unq(body["source"])).resolve()
        if src not in registry:
            print(f"{directory}: module.{name} source not found: {body['source']}")
            errors += 1
            continue
        mvars = registry[src][0]["variable"]
        passed = {k for k in body if k not in ("source", "count", "for_each", "depends_on", "providers", "version", "__is_block__", "__comments__")}
        for k in passed - set(mvars):
            print(f"{directory}: module.{name} passes unknown argument '{k}'")
            errors += 1
        for k, has_default in mvars.items():
            if not has_default and k not in passed:
                print(f"{directory}: module.{name} is missing required argument '{k}'")
                errors += 1
    return errors


def main(root: str) -> int:
    root_path = Path(root).resolve()
    dirs = sorted({p.parent for p in root_path.rglob("*.tf")})
    registry = {d: load(d) for d in dirs}
    errors = sum(check_dir(d, registry) for d in dirs)
    print(f"checked {len(dirs)} Terraform directories, {sum(len(list(d.glob('*.tf'))) for d in dirs)} files: "
          f"{'OK' if not errors else str(errors) + ' problem(s)'}")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else "terraform"))
