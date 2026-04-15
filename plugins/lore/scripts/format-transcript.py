#!/usr/bin/env python3
"""Format a Claude Code session transcript (JSONL) as markdown for ingestion.

Reads the transcript file passed as argv[1]. Each line is a JSON entry with
fields like `type`, `message`, `timestamp`. We render user + assistant turns
as markdown and skip tool-use noise that would bloat the ingest payload.

Output goes to stdout. Errors go to stderr and exit non-zero.
"""

from __future__ import annotations

import json
import sys
from typing import Any


def _extract_text(content: Any) -> str:
    """Pull plain text out of a message content field, which may be a string or
    a list of content blocks."""
    if isinstance(content, str):
        return content.strip()
    if isinstance(content, list):
        parts: list[str] = []
        for block in content:
            if not isinstance(block, dict):
                continue
            btype = block.get("type")
            if btype == "text":
                text = block.get("text", "")
                if isinstance(text, str) and text.strip():
                    parts.append(text.strip())
            # Intentionally skip tool_use / tool_result / image blocks — they
            # are mostly noise for wiki ingestion and bloat the payload.
        return "\n\n".join(parts).strip()
    return ""


def _format_entry(entry: dict[str, Any]) -> str | None:
    etype = entry.get("type")
    if etype not in ("user", "assistant"):
        return None
    message = entry.get("message") or {}
    content = message.get("content")
    text = _extract_text(content)
    if not text:
        return None
    speaker = "User" if etype == "user" else "Assistant"
    return f"**{speaker}:**\n\n{text}"


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: format-transcript.py <transcript.jsonl>", file=sys.stderr)
        return 2

    path = sys.argv[1]
    chunks: list[str] = []
    try:
        with open(path, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    entry = json.loads(line)
                except json.JSONDecodeError:
                    continue
                formatted = _format_entry(entry)
                if formatted:
                    chunks.append(formatted)
    except FileNotFoundError:
        print(f"transcript not found: {path}", file=sys.stderr)
        return 1

    if not chunks:
        return 0

    header = "# Claude session transcript\n"
    sys.stdout.write(header + "\n" + "\n\n---\n\n".join(chunks) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
