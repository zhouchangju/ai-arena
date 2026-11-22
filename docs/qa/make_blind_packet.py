#!/usr/bin/env python3
"""Package captured answers for independent, blinded quality review."""

import argparse
import hashlib
import json
import math
import os
import re
import secrets
from pathlib import Path

QUESTIONS = Path(__file__).with_name("decision-quality-questions.json")
VARIANTS = {"independent", "synthesis", "arena"}
IDENTITY_TERMS = {
    "ai arena", "chatgpt", "openai", "gpt-", "gemini", "deepseek", "claude",
    "anthropic", "qwen", "doubao", "kimi", "yuanbao", "copilot", "grok",
    "豆包", "通义千问", "腾讯元宝",
}

RUBRIC = """每份回答按四项各给 0、1 或 2 分。0 表示缺失或存在关键错误，1 表示有用但存在影响判断的缺口，2 表示充分且具体。

- **事实 (F)**：数字、口径与题面相符，推断有依据。证据不足时按已知信息作答。
- **纠错 (E)**：识别会影响结论的误算、错误前提或无依据归因，并说明修正如何改变判断。
- **反例 (C)**：保留最能动摇判断的反例、未决分歧或缺失信息，写明何时会改变结论。
- **行动 (A)**：给出符合材料、资源和期限的行动，必要时附条件、验证办法及调整标准。

每题给出排序（可并列）以及对应原句。优先记录改变判断或置信度的实质差异，即使总分相同也可以用原句证明差异。先完成并保存全卷，再核对答案键和来源。请独立记录有无身份线索，发生时写明题号和候选编号。
"""


def require(condition, message):
    if not condition:
        raise ValueError(message)


def annotate_answer(entry, base):
    variant = entry["variant"]
    require(variant in VARIANTS, "unknown variant")
    for field in ("model", "source_ref"):
        require(isinstance(entry[field], str) and entry[field].strip(), f"missing {field}")

    for field in ("elapsed_seconds", "web_interactions", "manual_steps"):
        value = entry[field]
        if field == "elapsed_seconds":
            valid = type(value) is int or (type(value) is float and math.isfinite(value))
            require(valid and value >= 0, f"invalid {field}")
        else:
            require(type(value) is int and value >= 0, f"invalid {field}")

    raw_file = base / entry["raw_file"]
    raw_bytes = raw_file.read_bytes()
    lines = raw_bytes.decode("utf-8").splitlines(keepends=True)
    start, end = entry.get("lines", [1, len(lines)])
    require(type(start) is int and type(end) is int and 1 <= start <= end <= len(lines),
            "invalid lines")
    answer = "".join(lines[start - 1:end]).strip()
    redactions = entry.get("redact", [])
    require(isinstance(redactions, list), "redact must contain a list of exact phrases")
    for phrase in redactions:
        require(isinstance(phrase, str) and phrase.strip() and phrase in answer,
                "redact phrase is empty or absent from chosen lines")
        answer = answer.replace(phrase, "[来源隐去]")
    require(answer and answer.replace("[来源隐去]", "").strip(), "empty answer")
    provenance = {**entry, "raw_sha256": hashlib.sha256(raw_bytes).hexdigest()}
    return answer, provenance


def fenced_text(answer):
    longest = max((len(match) for match in re.findall(r"`+", answer)), default=0)
    fence = "`" * max(3, longest + 1)
    return f"{fence}text\n{answer}\n{fence}"


def build_packet(questions, manifest, base):
    question_ids = {question["id"] for question in questions}
    require(set(manifest["questions"]) == question_ids, "manifest must cover exactly Q01–Q06")
    collection_terms = manifest.get("identity_terms", [])
    require(isinstance(collection_terms, list) and all(
        isinstance(term, str) and len(term.strip()) >= 2 for term in collection_terms
    ), "identity_terms must contain names with at least two characters")
    terms = IDENTITY_TERMS | {term.strip().casefold() for term in collection_terms}
    models = {
        entry["model"].strip().casefold()
        for entries in manifest["questions"].values()
        for entry in entries
        if isinstance(entry["model"], str)
    }
    terms.update(model for model in models if len(model) >= 2)

    reviewer = ["# 六题判断质量盲评", RUBRIC]
    key = {}
    randomizer = secrets.SystemRandom()
    for question in questions:
        question_id = question["id"]
        try:
            answers = [annotate_answer(entry, base) for entry in manifest["questions"][question_id]]
            variants = [entry["variant"] for _, entry in answers]
            require(variants.count("independent") >= 2 and variants.count("synthesis") == 1
                    and variants.count("arena") == 1,
                    "need at least two independent answers, one synthesis, and one final answer")
            independent = [entry["model"].strip().casefold() for _, entry in answers
                           if entry["variant"] == "independent"]
            require(len(set(independent)) == len(independent), "independent models must be distinct")
            require(len(answers) <= 26, "too many answers")
            randomizer.shuffle(answers)
            labels = []
            reviewer.extend([f"## {question_id}", question["prompt"]])
            key[question_id] = {"type": question["type"], "key": question["key"], "labels": {}}
            for index, (answer, entry) in enumerate(answers):
                label = chr(ord("A") + index)
                leaked = sorted(term for term in terms if term in answer.casefold())
                require(not leaked, f"identity terms remain in answer ({', '.join(leaked)})")
                labels.append(label)
                reviewer.extend([f"### 候选 {label}", fenced_text(answer)])
                key[question_id]["labels"][label] = entry
            reviewer.append(
                "| 候选 | F | E | C | A | 影响判断的原句、改动或遗漏 |\n"
                "| --- | --- | --- | --- | --- | --- |\n"
                + "\n".join(f"| {label} | | | | | |" for label in labels)
                + "\n\n排序（可并列）　\n\n身份线索（如有）　"
            )
        except (KeyError, TypeError, ValueError, OSError) as error:
            raise ValueError(f"{question_id}: {error}") from error
    return "\n\n".join(reviewer) + "\n", key


def write_private(path, data):
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, mode=0o600)
    with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
        handle.write(data)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("manifest", type=Path)
    parser.add_argument("new_private_output_dir", type=Path)
    args = parser.parse_args()
    try:
        questions = json.loads(QUESTIONS.read_text(encoding="utf-8"))
        manifest = json.loads(args.manifest.read_text(encoding="utf-8"))
        reviewer, key = build_packet(questions, manifest, args.manifest.parent)
        output = args.new_private_output_dir
        output.mkdir(mode=0o700)
        write_private(output / "private-key.json", json.dumps(key, ensure_ascii=False, indent=2) + "\n")
        write_private(output / "review.md", reviewer)
    except (KeyError, TypeError, ValueError, OSError) as error:
        parser.exit(2, f"{error}\n")
    print(output / "review.md")


if __name__ == "__main__":
    main()
