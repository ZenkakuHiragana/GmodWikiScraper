#!/usr/bin/env python3
"""Synchronize a compiled Garry's Mod Wiki corpus into LightRAG.

Modes
-----
Fresh workspace:
    import_gmodwiki_kg.py CORPUS --workspace gmodwiki --full

Existing workspace that was populated by the previous v1 importer:
    import_gmodwiki_kg.py CORPUS --workspace gmodwiki --adopt-current

Normal operation after a baseline state exists:
    import_gmodwiki_kg.py CORPUS --workspace gmodwiki

The normal mode performs an object-level diff:
- new/changed chunks are embedded/upserted;
- new/changed entities are created/edited;
- new/changed relationships are created/edited;
- obsolete relationships/entities/chunks are deleted;
- unchanged objects are untouched and are not re-embedded.

The importer intentionally does not use an LLM. If any code path tries to call
the configured LLM while importing, the operation fails.

IMPORTANT:
Stop lightrag-server before writes when using the same local
Json/NetworkX/NanoVectorDB working directory.
"""

from __future__ import annotations

import argparse
import asyncio
import hashlib
import json
import math
import os
import re
import sys
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable

STATE_FORMAT = "gmodwiki-lightrag-import-state-v2"


def parse_cli() -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument(
        "corpus",
        type=Path,
        help="directory produced by build_gmodwiki_kg.py",
    )
    p.add_argument(
        "--working-dir",
        type=Path,
        help="override LightRAG WORKING_DIR from .env",
    )
    p.add_argument(
        "--workspace",
        default="gmodwiki",
        help="LightRAG workspace to populate (default: gmodwiki)",
    )

    mode = p.add_mutually_exclusive_group()
    mode.add_argument(
        "--full",
        action="store_true",
        help="full import; intended for an empty/fresh workspace",
    )
    mode.add_argument(
        "--adopt-current",
        action="store_true",
        help=(
            "write baseline state without touching LightRAG; use once when the "
            "workspace was populated from this exact corpus by the previous importer"
        ),
    )

    p.add_argument(
        "--dry-run",
        action="store_true",
        help="show the incremental plan without modifying LightRAG or the state file",
    )
    p.add_argument(
        "--state-file",
        type=Path,
        help="override the importer state file location",
    )
    p.add_argument(
        "--progress-seconds",
        type=float,
        default=2.0,
        help="minimum interval between non-TTY progress lines (default: 2)",
    )
    return p.parse_args()


def read_jsonl(path: Path) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []

    with path.open("r", encoding="utf-8") as f:
        for line_number, line in enumerate(f, 1):
            line = line.strip()
            if not line:
                continue

            try:
                value = json.loads(line)
            except json.JSONDecodeError as exc:
                raise ValueError(
                    f"Invalid JSON at {path}:{line_number}: {exc}"
                ) from exc

            if not isinstance(value, dict):
                raise ValueError(
                    f"Expected JSON object at {path}:{line_number}"
                )

            rows.append(value)

    return rows


def stable_digest(value: Any) -> str:
    encoded = json.dumps(
        value,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def relation_state_key(src: str, tgt: str) -> str:
    # JSON encoding avoids delimiter escaping rules in entity names.
    return json.dumps([src, tgt], ensure_ascii=False, separators=(",", ":"))


def safe_workspace_name(workspace: str) -> str:
    value = workspace or "default"
    return re.sub(r"[^A-Za-z0-9_.-]+", "_", value)


def default_state_path(working_dir: Path, workspace: str) -> Path:
    return (
        working_dir
        / ".gmodwiki-import-state"
        / f"{safe_workspace_name(workspace)}.json"
    )


def atomic_write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = (
        json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True)
        + "\n"
    )

    fd, temp_name = tempfile.mkstemp(
        prefix=f".{path.name}.",
        suffix=".tmp",
        dir=path.parent,
        text=True,
    )
    temp = Path(temp_name)
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as f:
            f.write(payload)
            f.flush()
            os.fsync(f.fileno())
        os.replace(temp, path)
    finally:
        if temp.exists():
            temp.unlink(missing_ok=True)


def load_state(path: Path) -> dict[str, Any] | None:
    if not path.is_file():
        return None

    state = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(state, dict):
        raise ValueError(f"Importer state is not an object: {path}")
    if state.get("format") != STATE_FORMAT:
        raise ValueError(
            f"Unsupported importer state format at {path}: "
            f"{state.get('format')!r}"
        )
    return state


def format_duration(seconds: float | None) -> str:
    if seconds is None or not math.isfinite(seconds):
        return "--:--"
    seconds = max(0, int(seconds))
    hours, rem = divmod(seconds, 3600)
    minutes, secs = divmod(rem, 60)
    if hours:
        return f"{hours:02d}:{minutes:02d}:{secs:02d}"
    return f"{minutes:02d}:{secs:02d}"


class Progress:
    """Small dependency-free progress reporter.

    TTY: one updating line.
    Non-TTY/log: one line at most every `interval` seconds, plus completion.
    """

    def __init__(
        self,
        label: str,
        total: int,
        *,
        interval: float = 2.0,
        stream=None,
    ) -> None:
        self.label = label
        self.total = max(0, int(total))
        self.done = 0
        self.started = time.monotonic()
        self.last_print = 0.0
        self.interval = max(0.1, float(interval))
        self.stream = stream or sys.stderr
        self.tty = bool(getattr(self.stream, "isatty", lambda: False)())
        self._closed = False
        self.render(force=True)

    def advance(self, count: int = 1) -> None:
        self.done += max(0, int(count))
        self.render()

    def render(self, force: bool = False) -> None:
        if self._closed:
            return

        now = time.monotonic()
        if not force and not self.tty and now - self.last_print < self.interval:
            return

        elapsed = max(0.0, now - self.started)
        if self.total:
            shown_done = min(self.done, self.total)
            pct = 100.0 * shown_done / self.total
            rate = self.done / elapsed if elapsed > 0 else 0.0
            remaining = max(0, self.total - self.done)
            eta = remaining / rate if rate > 0 else None
            message = (
                f"{self.label}: {shown_done}/{self.total} "
                f"({pct:5.1f}%) elapsed={format_duration(elapsed)} "
                f"eta={format_duration(eta)}"
            )
        else:
            message = (
                f"{self.label}: {self.done} "
                f"elapsed={format_duration(elapsed)}"
            )

        if self.tty:
            print("\r" + message.ljust(96), end="", file=self.stream, flush=True)
        else:
            print(message, file=self.stream, flush=True)

        self.last_print = now

    def finish(self) -> None:
        if self._closed:
            return
        self.render(force=True)
        if self.tty:
            print(file=self.stream, flush=True)
        self._closed = True


async def forbidden_llm(*_args, **_kwargs):
    raise RuntimeError(
        "LLM invocation attempted during deterministic Garry's Mod Wiki import. "
        "The importer refuses to generate or summarize knowledge with an LLM."
    )


@dataclass
class CorpusModel:
    manifest: dict[str, Any]
    raw_chunks: list[dict[str, Any]]
    raw_entities: list[dict[str, Any]]
    raw_relationships: list[dict[str, Any]]

    # Effective objects after applying LightRAG's custom-KG identity rules.
    chunks: dict[str, dict[str, Any]]
    entities: dict[str, dict[str, Any]]
    relationships: dict[str, dict[str, Any]]

    # Logical source id -> actual chunk hash used as provenance by graph objects.
    source_to_chunk: dict[str, str]

    # State persisted after a successful sync.
    state: dict[str, Any]


def build_corpus_model(
    corpus: Path,
    *,
    compute_mdhash_id,
    normalize_entity_name,
    sanitize_text_for_encoding,
) -> CorpusModel:
    manifest_path = corpus / "manifest.json"
    if not manifest_path.is_file():
        raise FileNotFoundError(f"Missing manifest: {manifest_path}")

    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    if manifest.get("format") != "gmodwiki-lightrag-custom-kg-v1":
        raise ValueError(
            f"Unsupported corpus format: {manifest.get('format')!r}"
        )

    raw_chunks = read_jsonl(corpus / "chunks.jsonl")
    raw_entities = read_jsonl(corpus / "entities.jsonl")
    raw_relationships = read_jsonl(corpus / "relationships.jsonl")

    expected = manifest.get("counts", {})
    actual = {
        "entities": len(raw_entities),
        "chunks": len(raw_chunks),
        "relationships": len(raw_relationships),
    }
    for key, value in actual.items():
        if expected.get(key) != value:
            raise ValueError(
                f"Corpus count mismatch for {key}: "
                f"manifest={expected.get(key)!r}, actual={value}"
            )

    effective_chunks: dict[str, dict[str, Any]] = {}
    source_to_chunk: dict[str, str] = {}

    # ainsert_custom_kg hashes the sanitized content and keeps the last row
    # for duplicate content hashes. It also keeps the last chunk for a logical
    # source_id in chunk_to_source_map.
    for row in raw_chunks:
        content = sanitize_text_for_encoding(str(row["content"]))
        chunk_id = compute_mdhash_id(content, prefix="chunk-")
        logical_source_id = str(row["source_id"])
        payload = {
            "chunk_id": chunk_id,
            "content": content,
            "source_id": logical_source_id,
            "file_path": str(row.get("file_path", "custom_kg")),
            # The v1 builder writes source_chunk_index; LightRAG custom-KG
            # ingestion ignores it and uses 0. Keep that behavior stable so
            # adopting an existing v1 workspace does not force mass rewrites.
            "chunk_order_index": int(row.get("chunk_order_index", 0)),
        }
        effective_chunks[chunk_id] = payload
        source_to_chunk[logical_source_id] = chunk_id

    effective_entities: dict[str, dict[str, Any]] = {}
    for row in raw_entities:
        name = normalize_entity_name(str(row["entity_name"]))
        if not name:
            raise ValueError(
                f"Entity name became empty after LightRAG normalization: {row!r}"
            )

        logical_source_id = str(row.get("source_id", "UNKNOWN"))
        payload = {
            "entity_name": name,
            "entity_type": str(row.get("entity_type", "UNKNOWN")),
            "description": str(
                row.get("description", "No description provided")
            ),
            "source_id": source_to_chunk.get(logical_source_id, "UNKNOWN"),
            "file_path": str(row.get("file_path", "custom_kg")),
        }
        # LightRAG custom-KG keeps the last declaration for a normalized name.
        effective_entities[name] = payload

    effective_relationships: dict[str, dict[str, Any]] = {}
    for row in raw_relationships:
        src = normalize_entity_name(str(row["src_id"]))
        tgt = normalize_entity_name(str(row["tgt_id"]))
        if not src or not tgt:
            raise ValueError(
                f"Relationship endpoint became empty after normalization: {row!r}"
            )
        if src == tgt:
            raise ValueError(f"Self-loop after normalization: {src!r}")

        src, tgt = sorted((src, tgt))
        logical_source_id = str(row.get("source_id", "UNKNOWN"))
        payload = {
            "src_id": src,
            "tgt_id": tgt,
            "description": str(row.get("description", "")),
            "keywords": str(row.get("keywords", "")),
            "weight": float(row.get("weight", 1.0)),
            "source_id": source_to_chunk.get(logical_source_id, "UNKNOWN"),
            "file_path": str(row.get("file_path", "custom_kg")),
        }
        # Relationship storage is undirected; LightRAG keeps the last
        # declaration for an endpoint pair.
        effective_relationships[relation_state_key(src, tgt)] = payload

    state = {
        "format": STATE_FORMAT,
        "workspace": None,  # set by caller
        "corpus": {
            "source_sha256": (manifest.get("source") or {}).get("sha256"),
            "compiler": manifest.get("compiler"),
            "counts": manifest.get("counts"),
        },
        "objects": {
            "chunks": {
                chunk_id: stable_digest(
                    {
                        "content": payload["content"],
                        "source_id": payload["source_id"],
                        "file_path": payload["file_path"],
                        "chunk_order_index": payload["chunk_order_index"],
                    }
                )
                for chunk_id, payload in sorted(effective_chunks.items())
            },
            "entities": {
                name: stable_digest(payload)
                for name, payload in sorted(effective_entities.items())
            },
            "relationships": {
                key: {
                    "src_id": payload["src_id"],
                    "tgt_id": payload["tgt_id"],
                    "digest": stable_digest(payload),
                }
                for key, payload in sorted(effective_relationships.items())
            },
        },
    }

    return CorpusModel(
        manifest=manifest,
        raw_chunks=raw_chunks,
        raw_entities=raw_entities,
        raw_relationships=raw_relationships,
        chunks=effective_chunks,
        entities=effective_entities,
        relationships=effective_relationships,
        source_to_chunk=source_to_chunk,
        state=state,
    )


@dataclass
class DiffPlan:
    chunk_upserts: list[str]
    chunk_deletes: list[str]
    entity_creates: list[str]
    entity_updates: list[str]
    entity_deletes: list[str]
    relation_creates: list[str]
    relation_updates: list[str]
    relation_deletes: list[tuple[str, str]]

    @property
    def embedding_count(self) -> int:
        return (
            len(self.chunk_upserts)
            + len(self.entity_creates)
            + len(self.entity_updates)
            + len(self.relation_creates)
            + len(self.relation_updates)
        )

    @property
    def mutation_count(self) -> int:
        return (
            self.embedding_count
            + len(self.chunk_deletes)
            + len(self.entity_deletes)
            + len(self.relation_deletes)
        )


def compute_diff(
    previous: dict[str, Any],
    current: CorpusModel,
) -> DiffPlan:
    old_objects = previous.get("objects") or {}
    old_chunks: dict[str, str] = dict(old_objects.get("chunks") or {})
    old_entities: dict[str, str] = dict(old_objects.get("entities") or {})
    old_relations: dict[str, dict[str, Any]] = dict(
        old_objects.get("relationships") or {}
    )

    new_chunks = current.state["objects"]["chunks"]
    new_entities = current.state["objects"]["entities"]
    new_relations = current.state["objects"]["relationships"]

    chunk_upserts = sorted(
        key
        for key, digest in new_chunks.items()
        if old_chunks.get(key) != digest
    )
    chunk_deletes = sorted(set(old_chunks) - set(new_chunks))

    entity_creates = sorted(set(new_entities) - set(old_entities))
    entity_updates = sorted(
        key
        for key in set(new_entities) & set(old_entities)
        if new_entities[key] != old_entities[key]
    )
    entity_deletes = sorted(set(old_entities) - set(new_entities))

    relation_creates = sorted(set(new_relations) - set(old_relations))
    relation_updates = sorted(
        key
        for key in set(new_relations) & set(old_relations)
        if new_relations[key]["digest"] != old_relations[key]["digest"]
    )

    relation_deletes = []
    for key in sorted(set(old_relations) - set(new_relations)):
        row = old_relations[key]
        relation_deletes.append((str(row["src_id"]), str(row["tgt_id"])))

    return DiffPlan(
        chunk_upserts=chunk_upserts,
        chunk_deletes=chunk_deletes,
        entity_creates=entity_creates,
        entity_updates=entity_updates,
        entity_deletes=entity_deletes,
        relation_creates=relation_creates,
        relation_updates=relation_updates,
        relation_deletes=relation_deletes,
    )


def print_plan(plan: DiffPlan) -> None:
    print("Incremental sync plan:")
    print(f"  chunks:        +/~ {len(plan.chunk_upserts):6d}   - {len(plan.chunk_deletes):6d}")
    print(
        f"  entities:      + {len(plan.entity_creates):6d}   "
        f"~ {len(plan.entity_updates):6d}   - {len(plan.entity_deletes):6d}"
    )
    print(
        f"  relationships: + {len(plan.relation_creates):6d}   "
        f"~ {len(plan.relation_updates):6d}   - {len(plan.relation_deletes):6d}"
    )
    print(f"  embeddings expected: {plan.embedding_count}")
    print(f"  total mutations:     {plan.mutation_count}")


def attach_embedding_progress(
    embedding_func,
    *,
    total: int,
    interval: float,
) -> Progress:
    progress = Progress("Embedding", total, interval=interval)
    original_func = embedding_func.func

    async def tracked_embedding(
        texts,
        embedding_dim=None,
        context="document",
    ):
        result = await original_func(
            texts,
            embedding_dim=embedding_dim,
            context=context,
        )
        progress.advance(len(texts))
        return result

    embedding_func.func = tracked_embedding
    return progress


async def graph_has_edge(graph, src: str, tgt: str) -> bool:
    # Base graph storage implementations expose has_edge. Keep this tiny
    # adapter in one place because the importer otherwise uses public
    # LightRAG graph mutation methods.
    return bool(await graph.has_edge(src, tgt))


async def delete_chunk_ids(rag, chunk_ids: list[str]) -> None:
    if not chunk_ids:
        return

    # LightRAG's own document purge deletes the same two namespaces:
    # chunks_vdb (semantic retrieval) and text_chunks (chunk body storage).
    # Custom-KG ingestion does not create document recovery anchors, so the
    # document-level delete API cannot safely own these rows for us.
    await asyncio.gather(
        rag.chunks_vdb.delete(chunk_ids),
        rag.text_chunks.delete(chunk_ids),
    )

    # Flush only the two affected storages. If either flush fails the state
    # file is not advanced, so the next invocation retries the same diff.
    results = await asyncio.gather(
        rag.chunks_vdb.index_done_callback(),
        rag.text_chunks.index_done_callback(),
        return_exceptions=True,
    )
    errors = [x for x in results if isinstance(x, BaseException)]
    if errors:
        raise RuntimeError(
            "Failed to persist stale chunk deletion: "
            + "; ".join(str(x) for x in errors)
        )


async def full_import(
    rag,
    model: CorpusModel,
    *,
    interval: float,
) -> None:
    total_embeddings = (
        len(model.chunks)
        + len(model.entities)
        + len(model.relationships)
    )
    progress = attach_embedding_progress(
        rag.embedding_func,
        total=total_embeddings,
        interval=interval,
    )

    print(
        "Full import: "
        f"{len(model.raw_chunks)} chunk declarations, "
        f"{len(model.raw_entities)} entity declarations, "
        f"{len(model.raw_relationships)} relationship declarations"
    )
    print(
        "Effective vector objects: "
        f"{len(model.chunks)} chunks + "
        f"{len(model.entities)} entities + "
        f"{len(model.relationships)} relationships "
        f"= {total_embeddings} embeddings"
    )

    try:
        await rag.ainsert_custom_kg(
            {
                "chunks": model.raw_chunks,
                "entities": model.raw_entities,
                "relationships": model.raw_relationships,
            }
        )
    finally:
        progress.finish()


async def incremental_sync(
    rag,
    model: CorpusModel,
    plan: DiffPlan,
    *,
    interval: float,
) -> None:
    if plan.mutation_count == 0:
        print("Corpus is already synchronized; no LightRAG writes required.")
        return

    embedding_progress = attach_embedding_progress(
        rag.embedding_func,
        total=plan.embedding_count,
        interval=interval,
    )

    try:
        # 1. Make every new provenance chunk available before graph objects
        #    are pointed at it.
        if plan.chunk_upserts:
            print(f"[1/6] Upserting {len(plan.chunk_upserts)} chunk(s)...")
            rows = []
            for chunk_id in plan.chunk_upserts:
                payload = model.chunks[chunk_id]
                rows.append(
                    {
                        "content": payload["content"],
                        "source_id": payload["source_id"],
                        "file_path": payload["file_path"],
                        "chunk_order_index": payload["chunk_order_index"],
                    }
                )
            await rag.ainsert_custom_kg(
                {"chunks": rows, "entities": [], "relationships": []}
            )
        else:
            print("[1/6] No chunk upserts.")

        # 2. Entities first so every new relation endpoint exists.
        entity_names = plan.entity_creates + plan.entity_updates
        if entity_names:
            print(f"[2/6] Creating/updating {len(entity_names)} entity(ies)...")
            phase = Progress(
                "Entities",
                len(entity_names),
                interval=interval,
            )
            try:
                for name in entity_names:
                    payload = model.entities[name]
                    data = {
                        "description": payload["description"],
                        "entity_type": payload["entity_type"],
                        "source_id": payload["source_id"],
                        "file_path": payload["file_path"],
                    }

                    # Resume-safe: a previous interrupted run may already have
                    # created an entity that the state file still calls "new".
                    if await rag.chunk_entity_relation_graph.has_node(name):
                        await rag.aedit_entity(
                            entity_name=name,
                            updated_data=data,
                            allow_rename=False,
                            allow_merge=False,
                        )
                    else:
                        await rag.acreate_entity(
                            entity_name=name,
                            entity_data=data,
                        )
                    phase.advance()
            finally:
                phase.finish()
        else:
            print("[2/6] No entity creates/updates.")

        # 3. Relations.
        relation_keys = plan.relation_creates + plan.relation_updates
        if relation_keys:
            print(
                f"[3/6] Creating/updating {len(relation_keys)} relationship(s)..."
            )
            phase = Progress(
                "Relationships",
                len(relation_keys),
                interval=interval,
            )
            try:
                for key in relation_keys:
                    payload = model.relationships[key]
                    src = payload["src_id"]
                    tgt = payload["tgt_id"]
                    data = {
                        "description": payload["description"],
                        "keywords": payload["keywords"],
                        "weight": payload["weight"],
                        "source_id": payload["source_id"],
                        "file_path": payload["file_path"],
                    }

                    # Resume-safe for the same reason as entity creation.
                    if await graph_has_edge(
                        rag.chunk_entity_relation_graph,
                        src,
                        tgt,
                    ):
                        await rag.aedit_relation(
                            source_entity=src,
                            target_entity=tgt,
                            updated_data=data,
                        )
                    else:
                        await rag.acreate_relation(
                            source_entity=src,
                            target_entity=tgt,
                            relation_data=data,
                        )
                    phase.advance()
            finally:
                phase.finish()
        else:
            print("[3/6] No relationship creates/updates.")

        # 4. Relations that are no longer in the mechanically derived graph.
        if plan.relation_deletes:
            print(
                f"[4/6] Deleting {len(plan.relation_deletes)} stale relationship(s)..."
            )
            phase = Progress(
                "Delete relationships",
                len(plan.relation_deletes),
                interval=interval,
            )
            try:
                for src, tgt in plan.relation_deletes:
                    result = await rag.adelete_by_relation(
                        source_entity=src,
                        target_entity=tgt,
                    )
                    if result.status not in {"success", "not_found"}:
                        raise RuntimeError(
                            f"Failed deleting relation {src!r} <-> {tgt!r}: "
                            f"{result.status}: {result.message}"
                        )
                    phase.advance()
            finally:
                phase.finish()
        else:
            print("[4/6] No stale relationships.")

        # 5. Removed pages. Entity deletion also removes any residual incident
        #    relations, which is desired because a relationship cannot survive
        #    when one of its Wiki-page endpoints no longer exists.
        if plan.entity_deletes:
            print(f"[5/6] Deleting {len(plan.entity_deletes)} stale entity(ies)...")
            phase = Progress(
                "Delete entities",
                len(plan.entity_deletes),
                interval=interval,
            )
            try:
                for name in plan.entity_deletes:
                    result = await rag.adelete_by_entity(entity_name=name)
                    if result.status not in {"success", "not_found"}:
                        raise RuntimeError(
                            f"Failed deleting entity {name!r}: "
                            f"{result.status}: {result.message}"
                        )
                    phase.advance()
            finally:
                phase.finish()
        else:
            print("[5/6] No stale entities.")

        # 6. Old chunk hashes are safe to remove only after every graph object
        #    has been repointed/deleted.
        if plan.chunk_deletes:
            print(f"[6/6] Deleting {len(plan.chunk_deletes)} stale chunk(s)...")
            await delete_chunk_ids(rag, plan.chunk_deletes)
            print(f"Deleted {len(plan.chunk_deletes)} stale chunk(s).")
        else:
            print("[6/6] No stale chunks.")

    finally:
        embedding_progress.finish()


async def run(cli: argparse.Namespace) -> None:
    corpus = cli.corpus.resolve()
    if not corpus.is_dir():
        raise NotADirectoryError(f"Corpus directory does not exist: {corpus}")

    # LightRAG's server config lazily parses its own CLI arguments.
    # Remove this importer's arguments before importing that configuration.
    sys.argv = [sys.argv[0]]

    from lightrag import LightRAG
    from lightrag.api.config import get_config, get_default_host
    from lightrag.api.lightrag_server import (
        create_embedding_function_from_args,
    )
    from lightrag.utils import (
        compute_mdhash_id,
        normalize_entity_name,
        sanitize_text_for_encoding,
    )

    args = get_config()

    if cli.working_dir is not None:
        args.working_dir = str(cli.working_dir.resolve())

    args.workspace = cli.workspace

    working_dir = Path(args.working_dir).resolve()
    state_path = (
        cli.state_file.resolve()
        if cli.state_file is not None
        else default_state_path(working_dir, cli.workspace)
    )

    model = build_corpus_model(
        corpus,
        compute_mdhash_id=compute_mdhash_id,
        normalize_entity_name=normalize_entity_name,
        sanitize_text_for_encoding=sanitize_text_for_encoding,
    )
    model.state["workspace"] = cli.workspace

    previous = load_state(state_path)

    print(f"Corpus:     {corpus}")
    print(f"Workspace:  {cli.workspace!r}")
    print(f"Working dir:{working_dir}")
    print(f"State:      {state_path}")
    print(
        "Effective corpus: "
        f"{len(model.chunks)} chunks, "
        f"{len(model.entities)} entities, "
        f"{len(model.relationships)} relationships"
    )

    if cli.adopt_current:
        if previous is not None:
            raise RuntimeError(
                f"State already exists: {state_path}. "
                "--adopt-current is only for creating the initial baseline."
            )
        if cli.dry_run:
            print("Would adopt current corpus as the baseline; no file written.")
            return

        atomic_write_json(state_path, model.state)
        print(
            "Baseline adopted. LightRAG was not modified. "
            "Future runs without --full/--adopt-current will be incremental."
        )
        return

    if previous is None and not cli.full:
        raise RuntimeError(
            "No importer state exists for this workspace. "
            "If this workspace was just populated by the previous importer "
            "from this exact corpus, run once with --adopt-current. "
            "For a fresh empty workspace, run with --full."
        )

    if previous is not None and previous.get("workspace") != cli.workspace:
        raise RuntimeError(
            f"State workspace mismatch: state={previous.get('workspace')!r}, "
            f"requested={cli.workspace!r}"
        )

    if cli.full:
        if cli.dry_run:
            print(
                "Would perform a full custom-KG import into the selected workspace."
            )
            return
    else:
        plan = compute_diff(previous, model)
        print_plan(plan)
        if cli.dry_run:
            return
        if plan.mutation_count == 0:
            # Advance corpus metadata even when object identity is unchanged
            # (e.g. source YAML comments/ordering changed).
            atomic_write_json(state_path, model.state)
            print("State metadata updated.")
            return

    if args.embedding_binding_host is None:
        args.embedding_binding_host = get_default_host(
            args.embedding_binding
        )

    embedding_func = create_embedding_function_from_args(args)

    rag = LightRAG(
        working_dir=str(working_dir),
        workspace=args.workspace,
        llm_model_func=forbidden_llm,
        llm_model_name="disabled-deterministic-import",
        embedding_func=embedding_func,
        kv_storage=args.kv_storage,
        graph_storage=args.graph_storage,
        vector_storage=args.vector_storage,
        doc_status_storage=args.doc_status_storage,
        vector_db_storage_cls_kwargs={
            "cosine_better_than_threshold": args.cosine_threshold
        },
        embedding_chunk_overlap_token_size=int(
            args.embedding_chunk_overlap_token_size
        ),
    )

    initialized = False
    try:
        print("Initializing LightRAG storages...")
        await rag.initialize_storages()
        initialized = True
        await rag.check_and_migrate_data()

        if cli.full:
            # This remains a direct custom-KG import, deliberately preserving
            # the exact semantics of the original importer. It is intended for
            # a fresh workspace. Subsequent runs should use incremental mode.
            await full_import(
                rag,
                model,
                interval=cli.progress_seconds,
            )
        else:
            await incremental_sync(
                rag,
                model,
                plan,
                interval=cli.progress_seconds,
            )

    finally:
        if initialized:
            print("Finalizing LightRAG storages...")
            await rag.finalize_storages()

    # The state advances only after every storage mutation has completed.
    # An interrupted/failed run therefore retries from the previous known
    # corpus on the next invocation. Mutation operations are written to be
    # idempotent/resume-safe.
    atomic_write_json(state_path, model.state)
    print("Synchronization completed.")
    print(f"State updated: {state_path}")


def main() -> int:
    cli = parse_cli()
    asyncio.run(run(cli))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        print("\nInterrupted", file=sys.stderr)
        raise SystemExit(130)
