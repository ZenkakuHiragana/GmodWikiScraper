#!/usr/bin/env python3
"""Compile allpages-slim.yml into deterministic LightRAG custom-KG input.

No LLM is used.

Mapping:
- one Garry's Mod Wiki page -> one graph entity
- page content -> one or more vector-search chunks
- explicit <page>...</page> references -> graph relationships
- relationship description -> source text surrounding that explicit reference

Outputs:
- manifest.json
- entities.jsonl
- chunks.jsonl
- relationships.jsonl
- unresolved-links.jsonl
"""

from __future__ import annotations

import argparse
import hashlib
import html
import json
import os
import re
import shutil
import sys
import tempfile
from collections import defaultdict
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, Sequence
from urllib.parse import quote, unquote

import tiktoken
import yaml

DEFAULT_BASE_URL = "https://wiki.facepunch.com/gmod/"
DEFAULT_TARGET_TOKENS = 900
DEFAULT_MAX_TOKENS = 1200
DEFAULT_SYNOPSIS_TOKENS = 700
ROOT_ENTITY = "__gmodwiki_root__"
SOURCE_PREFIX = "gmodwiki:"

PAGE_RE = re.compile(
    r"<page\b(?P<attrs>[^>]*)>(?P<target>.*?)</page>",
    re.IGNORECASE | re.DOTALL,
)
FENCED_CODE_RE = re.compile(r"```.*?```", re.DOTALL)
XML_CODE_RE = re.compile(r"<code\b[^>]*>.*?</code>", re.IGNORECASE | re.DOTALL)
HEADING_RE = re.compile(r"(?m)^#{1,6}\s+.+$")
TAG_RE_TEMPLATE = r"<{tag}\b[^>]*>(.*?)</{tag}>"
ANY_TAG_RE = re.compile(r"<[^>]+>")
MARKDOWN_LINK_RE = re.compile(r"\[([^\]]+)\]\([^)]*\)")
MULTISPACE_RE = re.compile(r"[ \t\r\f\v]+")
MANY_NEWLINES_RE = re.compile(r"\n{3,}")


@dataclass(frozen=True)
class Page:
    title: str
    tags: str
    address: str
    markup: str

    @property
    def entity_name(self) -> str:
        return self.address or ROOT_ENTITY

    @property
    def source_id(self) -> str:
        return SOURCE_PREFIX + self.entity_name


@dataclass(frozen=True)
class LinkResolution:
    raw_target: str
    entity_name: str | None
    method: str | None


class Tokenizer:
    def __init__(self, model: str) -> None:
        try:
            self.encoding = tiktoken.encoding_for_model(model)
        except KeyError:
            self.encoding = tiktoken.get_encoding("o200k_base")

    def count(self, text: str) -> int:
        return len(self.encoding.encode(text, disallowed_special=()))

    def split_windowed(
        self,
        text: str,
        max_tokens: int,
        overlap_tokens: int = 0,
    ) -> list[str]:
        ids = self.encoding.encode(text, disallowed_special=())
        if len(ids) <= max_tokens:
            return [text]
        if overlap_tokens >= max_tokens:
            raise ValueError("overlap_tokens must be smaller than max_tokens")

        step = max_tokens - overlap_tokens
        out: list[str] = []
        for start in range(0, len(ids), step):
            part = ids[start : start + max_tokens]
            if not part:
                break
            decoded = self.encoding.decode(part).strip()
            if decoded:
                out.append(decoded)
            if start + max_tokens >= len(ids):
                break
        return out

    def truncate(self, text: str, max_tokens: int) -> str:
        ids = self.encoding.encode(text, disallowed_special=())
        if len(ids) <= max_tokens:
            return text
        return self.encoding.decode(ids[:max_tokens]).rstrip()


class PageIndex:
    def __init__(self, pages: Sequence[Page]) -> None:
        self.by_address: dict[str, Page] = {}
        self.by_title: dict[str, list[Page]] = defaultdict(list)
        self.by_normalized_address: dict[str, list[Page]] = defaultdict(list)
        self.by_normalized_title: dict[str, list[Page]] = defaultdict(list)

        for page in pages:
            if page.address in self.by_address:
                raise ValueError(f"Duplicate page address: {page.address!r}")
            self.by_address[page.address] = page
            self.by_title[page.title].append(page)
            self.by_normalized_address[self._normalize(page.address)].append(page)
            self.by_normalized_title[self._normalize(page.title)].append(page)

    @staticmethod
    def _clean_target(raw: str) -> str:
        target = html.unescape(raw)
        target = ANY_TAG_RE.sub("", target)
        target = unquote(target).strip()
        if target.startswith(DEFAULT_BASE_URL):
            target = target[len(DEFAULT_BASE_URL) :]
        target = target.lstrip("/")
        if "#" in target:
            target = target.split("#", 1)[0]
        return target.strip()

    @staticmethod
    def _normalize(value: str) -> str:
        value = html.unescape(unquote(value)).strip()
        value = value.replace("\\", "/")
        value = value.replace(" ", "_")
        value = re.sub(r"_+", "_", value)
        return value.casefold()

    @staticmethod
    def _unique(items: Sequence[Page]) -> Page | None:
        return items[0] if len(items) == 1 else None

    def resolve(self, raw_target: str) -> LinkResolution:
        cleaned = self._clean_target(raw_target)

        if cleaned in self.by_address:
            page = self.by_address[cleaned]
            return LinkResolution(raw_target, page.entity_name, "exact-address")

        underscore = cleaned.replace(" ", "_")
        if underscore in self.by_address:
            page = self.by_address[underscore]
            return LinkResolution(raw_target, page.entity_name, "space-to-underscore")

        page = self._unique(self.by_title.get(cleaned, []))
        if page is not None:
            return LinkResolution(raw_target, page.entity_name, "unique-title")

        normalized = self._normalize(cleaned)

        page = self._unique(self.by_normalized_address.get(normalized, []))
        if page is not None:
            return LinkResolution(raw_target, page.entity_name, "normalized-address")

        page = self._unique(self.by_normalized_title.get(normalized, []))
        if page is not None:
            return LinkResolution(raw_target, page.entity_name, "normalized-title")

        return LinkResolution(raw_target, None, None)


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("input", type=Path, help="allpages-slim.yml")
    p.add_argument("output", type=Path, help="output directory")
    p.add_argument("--base-url", default=DEFAULT_BASE_URL)
    p.add_argument("--tokenizer-model", default="gpt-4o-mini")
    p.add_argument("--target-tokens", type=int, default=DEFAULT_TARGET_TOKENS)
    p.add_argument("--max-tokens", type=int, default=DEFAULT_MAX_TOKENS)
    p.add_argument("--synopsis-tokens", type=int, default=DEFAULT_SYNOPSIS_TOKENS)
    p.add_argument(
        "--oversize-overlap-tokens",
        type=int,
        default=80,
        help="overlap used only when one structural block exceeds --max-tokens",
    )
    p.add_argument(
        "--force",
        action="store_true",
        help="replace an existing output directory after a successful build",
    )
    return p.parse_args()


def validate_args(args: argparse.Namespace) -> None:
    if not args.input.is_file():
        raise ValueError(f"Input file does not exist: {args.input}")
    if args.target_tokens <= 0 or args.max_tokens <= 0 or args.synopsis_tokens <= 0:
        raise ValueError("token limits must be positive")
    if args.target_tokens > args.max_tokens:
        raise ValueError("--target-tokens must be <= --max-tokens")
    if not 0 <= args.oversize_overlap_tokens < args.max_tokens:
        raise ValueError("--oversize-overlap-tokens must be in [0, max_tokens)")


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as f:
        for block in iter(lambda: f.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def load_pages(path: Path) -> list[Page]:
    raw = yaml.safe_load(path.read_text(encoding="utf-8"))
    if not isinstance(raw, list):
        raise ValueError("Top-level YAML value must be a list")

    pages: list[Page] = []
    for index, item in enumerate(raw):
        if not isinstance(item, dict):
            raise ValueError(f"Page #{index} is not a mapping")
        missing = {"title", "tags", "address", "markup"} - item.keys()
        if missing:
            raise ValueError(f"Page #{index} is missing fields: {sorted(missing)}")

        values = {k: item[k] for k in ("title", "tags", "address", "markup")}
        if any(v is None for v in values.values()):
            raise ValueError(f"Page #{index} contains null values")
        if not all(isinstance(v, str) for v in values.values()):
            raise ValueError(f"Page #{index} fields must all be strings")

        pages.append(Page(**values))
    return pages


def wiki_url(page: Page, base_url: str) -> str:
    base = base_url.rstrip("/") + "/"
    if not page.address:
        return base
    return base + quote(page.address, safe="/:_-.()")


def entity_type(page: Page) -> str:
    tags = set(page.tags.split())
    for tag in ("event", "panel", "struct", "enum", "function", "type", "shader"):
        if tag in tags:
            return tag
    return "wiki_page"


def replace_page_tags(text: str) -> str:
    return PAGE_RE.sub(lambda m: m.group("target").strip(), text)


def plain_text(markup: str) -> str:
    text = FENCED_CODE_RE.sub(" ", markup)
    text = XML_CODE_RE.sub(" ", text)
    text = replace_page_tags(text)
    text = MARKDOWN_LINK_RE.sub(r"\1", text)
    text = ANY_TAG_RE.sub(" ", text)
    text = html.unescape(text)
    text = MULTISPACE_RE.sub(" ", text)
    text = re.sub(r" *\n *", "\n", text)
    text = MANY_NEWLINES_RE.sub("\n\n", text)
    return text.strip()


def extract_tag_blocks(markup: str, tag: str) -> list[str]:
    pattern = re.compile(
        TAG_RE_TEMPLATE.format(tag=re.escape(tag)),
        re.IGNORECASE | re.DOTALL,
    )
    return [m.group(1).strip() for m in pattern.finditer(markup)]


def build_synopsis(page: Page, tokenizer: Tokenizer, max_tokens: int) -> str:
    parts = [f"Page: {page.entity_name}", f"Title: {page.title}"]
    if page.tags:
        parts.append(f"Tags: {page.tags}")

    body_parts: list[str] = []

    # The first <description> is normally the API/article's primary description.
    descriptions = extract_tag_blocks(page.markup, "description")
    if descriptions:
        primary = plain_text(descriptions[0])
        if primary:
            body_parts.append(primary)

    # Explicit cautions are high-signal for concern-driven retrieval.
    seen = set(body_parts)
    for tag in ("warning", "note", "bug", "deprecated"):
        for block in extract_tag_blocks(page.markup, tag):
            cleaned = plain_text(block)
            if (
                cleaned
                and cleaned not in seen
                and not any(cleaned in existing for existing in body_parts)
            ):
                seen.add(cleaned)
                body_parts.append(cleaned)

    # Non-API article fallback.
    if not body_parts:
        prose = plain_text(page.markup)
        if prose:
            body_parts.append(prose)

    if body_parts:
        parts.append("\n\n".join(body_parts))

    return tokenizer.truncate("\n".join(parts).strip(), max_tokens)


def scan_protected_spans(text: str) -> list[tuple[int, int]]:
    patterns = [
        re.compile(r"```.*?```", re.DOTALL),
        re.compile(r"<example\b[^>]*>.*?</example>", re.IGNORECASE | re.DOTALL),
        re.compile(r"<function\b[^>]*>.*?</function>", re.IGNORECASE | re.DOTALL),
    ]
    spans: list[tuple[int, int]] = []
    for pattern in patterns:
        spans.extend((m.start(), m.end()) for m in pattern.finditer(text))
    spans.sort()

    merged: list[tuple[int, int]] = []
    for start, end in spans:
        if merged and start < merged[-1][1]:
            if end > merged[-1][1]:
                merged[-1] = (merged[-1][0], end)
        else:
            merged.append((start, end))
    return merged


def split_plain_region(region: str) -> list[str]:
    region = region.strip()
    if not region:
        return []

    blocks: list[str] = []
    current: list[str] = []
    in_fence = False

    def flush() -> None:
        if current:
            block = "\n".join(current).strip()
            if block:
                blocks.append(block)
            current.clear()

    for line in region.splitlines():
        if line.lstrip().startswith("```"):
            in_fence = not in_fence
            current.append(line)
            continue

        if not in_fence and HEADING_RE.fullmatch(line.strip()):
            flush()
            current.append(line)
            continue

        if not in_fence and not line.strip():
            flush()
            continue

        current.append(line)

    flush()
    return blocks


def structural_blocks(markup: str) -> list[str]:
    spans = scan_protected_spans(markup)
    if not spans:
        return split_plain_region(markup)

    blocks: list[str] = []
    pos = 0
    for start, end in spans:
        if start > pos:
            blocks.extend(split_plain_region(markup[pos:start]))

        block = markup[start:end].strip()
        if block:
            blocks.append(block)
        pos = end

    if pos < len(markup):
        blocks.extend(split_plain_region(markup[pos:]))

    return blocks


def page_header(page: Page) -> str:
    lines = [f"Page: {page.entity_name}", f"Title: {page.title}"]
    if page.tags:
        lines.append(f"Tags: {page.tags}")
    return "\n".join(lines)


def build_chunks(
    page: Page,
    tokenizer: Tokenizer,
    target_tokens: int,
    max_tokens: int,
    oversize_overlap_tokens: int,
    base_url: str,
) -> list[dict]:
    header = page_header(page)
    header_tokens = tokenizer.count(header + "\n\n")
    if header_tokens >= max_tokens:
        raise ValueError(f"Page header alone exceeds max tokens: {page.entity_name}")

    full = f"{header}\n\n{page.markup.strip()}".strip()
    if tokenizer.count(full) <= max_tokens:
        return [
            {
                "content": full,
                "source_id": page.source_id,
                "source_chunk_index": 0,
                "file_path": wiki_url(page, base_url),
            }
        ]

    body_target = max(1, target_tokens - header_tokens)
    body_max = max(1, max_tokens - header_tokens)

    blocks = structural_blocks(page.markup) or [page.markup]
    normalized: list[str] = []

    def append_bounded(block: str) -> None:
        if tokenizer.count(block) <= body_max:
            normalized.append(block)
            return

        # A protected <function>/<example> block may itself be oversized.
        # Before falling back to raw token windows, try its own blank-line/
        # heading structure so we do not split markup unnecessarily.
        subblocks = split_plain_region(block)
        if len(subblocks) > 1:
            for subblock in subblocks:
                append_bounded(subblock)
            return

        normalized.extend(
            tokenizer.split_windowed(
                block,
                max_tokens=body_max,
                overlap_tokens=min(
                    oversize_overlap_tokens,
                    max(0, body_max - 1),
                ),
            )
        )

    for block in blocks:
        append_bounded(block)

    packed: list[str] = []
    current: list[str] = []
    current_tokens = 0

    for block in normalized:
        block_tokens = tokenizer.count(block)
        separator_tokens = 1 if current else 0

        if current and current_tokens + separator_tokens + block_tokens > body_target:
            packed.append("\n\n".join(current).strip())
            current = []
            current_tokens = 0
            separator_tokens = 0

        current.append(block)
        current_tokens += separator_tokens + block_tokens

    if current:
        packed.append("\n\n".join(current).strip())

    chunks: list[dict] = []
    for chunk_index, body in enumerate(p for p in packed if p):
        content = f"{header}\n\n{body}".strip()
        if tokenizer.count(content) > max_tokens:
            raise RuntimeError(
                f"Internal chunker error: {page.entity_name} chunk "
                f"{chunk_index} exceeds max tokens"
            )

        chunks.append(
            {
                "content": content,
                "source_id": page.source_id,
                "source_chunk_index": chunk_index,
                "file_path": wiki_url(page, base_url),
            }
        )

    return chunks


def enclosing_context(
    markup: str,
    start: int,
    end: int,
    max_chars: int = 700,
) -> str:
    before = markup.rfind("\n\n", 0, start)
    after = markup.find("\n\n", end)

    if before < 0:
        before = max(0, start - max_chars // 2)
    else:
        before += 2

    if after < 0:
        after = min(len(markup), end + max_chars // 2)

    cleaned = plain_text(markup[before:after].strip())
    if len(cleaned) > max_chars:
        cleaned = cleaned[:max_chars].rstrip()

    return cleaned


def build_relationships(
    page: Page,
    index: PageIndex,
    base_url: str,
) -> tuple[list[dict], list[dict], dict[str, int]]:
    grouped_contexts: dict[tuple[str, str], list[str]] = defaultdict(list)
    unresolved: list[dict] = []
    methods: dict[str, int] = defaultdict(int)

    for match in PAGE_RE.finditer(page.markup):
        raw_target = match.group("target").strip()
        resolution = index.resolve(raw_target)
        context = enclosing_context(page.markup, match.start(), match.end())

        if resolution.entity_name is None:
            unresolved.append(
                {
                    "source": page.entity_name,
                    "raw_target": raw_target,
                    "context": context,
                    "file_path": wiki_url(page, base_url),
                }
            )
            continue

        methods[resolution.method or "unknown"] += 1

        # Current LightRAG rejects custom-KG self loops.
        if resolution.entity_name == page.entity_name:
            continue

        key = (page.entity_name, resolution.entity_name)
        if context and context not in grouped_contexts[key]:
            grouped_contexts[key].append(context)

    relationships: list[dict] = []

    for (src, tgt), contexts in sorted(grouped_contexts.items()):
        description = " | ".join(contexts[:3])
        if not description:
            description = (
                f"Explicit Garry's Mod Wiki page reference from {src} to {tgt}."
            )

        relationships.append(
            {
                "src_id": src,
                "tgt_id": tgt,
                "description": description,
                "keywords": "wiki_reference",
                "weight": 1.0,
                "source_id": page.source_id,
                "file_path": wiki_url(page, base_url),
            }
        )

    return relationships, unresolved, methods


def write_jsonl(path: Path, rows: Iterable[dict]) -> int:
    count = 0
    with path.open("w", encoding="utf-8", newline="\n") as f:
        for row in rows:
            f.write(
                json.dumps(
                    row,
                    ensure_ascii=False,
                    sort_keys=True,
                    separators=(",", ":"),
                )
            )
            f.write("\n")
            count += 1
    return count


def install_completed_build(
    temp_dir: Path,
    output_dir: Path,
    force: bool,
) -> None:
    output_dir = output_dir.resolve()
    temp_dir = temp_dir.resolve()
    output_dir.parent.mkdir(parents=True, exist_ok=True)

    if output_dir.exists() and not force:
        raise FileExistsError(
            f"Output already exists: {output_dir} (use --force to replace it)"
        )

    backup: Path | None = None

    try:
        if output_dir.exists():
            backup = output_dir.parent / f".{output_dir.name}.backup-{os.getpid()}"
            if backup.exists():
                shutil.rmtree(backup)
            output_dir.rename(backup)

        temp_dir.rename(output_dir)

        if backup is not None and backup.exists():
            shutil.rmtree(backup)

    except Exception:
        if backup is not None and backup.exists() and not output_dir.exists():
            backup.rename(output_dir)
        raise


def main() -> int:
    args = parse_args()
    validate_args(args)

    pages = load_pages(args.input)
    page_index = PageIndex(pages)
    tokenizer = Tokenizer(args.tokenizer_model)

    output_parent = args.output.resolve().parent
    output_parent.mkdir(parents=True, exist_ok=True)

    temp_dir: Path | None = Path(
        tempfile.mkdtemp(
            prefix=f".{args.output.name}.build-",
            dir=output_parent,
        )
    )

    try:
        entities: list[dict] = []
        chunks: list[dict] = []
        relationships: list[dict] = []
        unresolved: list[dict] = []
        resolution_methods: dict[str, int] = defaultdict(int)

        for page in sorted(pages, key=lambda p: p.entity_name):
            entities.append(
                {
                    "entity_name": page.entity_name,
                    "entity_type": entity_type(page),
                    "description": build_synopsis(
                        page,
                        tokenizer,
                        args.synopsis_tokens,
                    ),
                    "source_id": page.source_id,
                    "file_path": wiki_url(page, args.base_url),
                }
            )

            chunks.extend(
                build_chunks(
                    page,
                    tokenizer,
                    args.target_tokens,
                    args.max_tokens,
                    args.oversize_overlap_tokens,
                    args.base_url,
                )
            )

            rels, missing, methods = build_relationships(
                page,
                page_index,
                args.base_url,
            )
            relationships.extend(rels)
            unresolved.extend(missing)

            for method, count in methods.items():
                resolution_methods[method] += count

        entities.sort(key=lambda x: x["entity_name"])
        chunks.sort(
            key=lambda x: (
                x["source_id"],
                x.get("source_chunk_index", 0),
            )
        )
        relationships.sort(key=lambda x: (x["src_id"], x["tgt_id"]))
        unresolved.sort(key=lambda x: (x["source"], x["raw_target"]))

        counts = {
            "pages": len(pages),
            "entities": write_jsonl(temp_dir / "entities.jsonl", entities),
            "chunks": write_jsonl(temp_dir / "chunks.jsonl", chunks),
            "relationships": write_jsonl(
                temp_dir / "relationships.jsonl",
                relationships,
            ),
            "unresolved_links": write_jsonl(
                temp_dir / "unresolved-links.jsonl",
                unresolved,
            ),
        }

        manifest = {
            "format": "gmodwiki-lightrag-custom-kg-v1",
            "source": {
                "path": str(args.input.resolve()),
                "sha256": sha256_file(args.input),
            },
            "compiler": {
                "tokenizer_model": args.tokenizer_model,
                "target_tokens": args.target_tokens,
                "max_tokens": args.max_tokens,
                "synopsis_tokens": args.synopsis_tokens,
                "oversize_overlap_tokens": args.oversize_overlap_tokens,
                "base_url": args.base_url,
            },
            "counts": counts,
            "link_resolution_methods": dict(sorted(resolution_methods.items())),
            "notes": [
                "All entities and relationships are derived mechanically.",
                "Relationships represent explicit <page> references only.",
                "unresolved-links.jsonl is diagnostic and is not imported.",
            ],
        }

        (temp_dir / "manifest.json").write_text(
            json.dumps(
                manifest,
                ensure_ascii=False,
                indent=2,
                sort_keys=True,
            )
            + "\n",
            encoding="utf-8",
        )

        install_completed_build(temp_dir, args.output, args.force)
        temp_dir = None

        print(json.dumps(manifest, ensure_ascii=False, indent=2))
        return 0

    finally:
        if temp_dir is not None and temp_dir.exists():
            shutil.rmtree(temp_dir, ignore_errors=True)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        print("Interrupted", file=sys.stderr)
        raise SystemExit(130)
