# Garry's Mod Wiki → LightRAG deterministic corpus

`allpages-slim.yml` を LightRAG 用の派生索引へ変換・同期するスクリプトです。

## 方針

- 1 Wiki page = 1 graph entity
- Wiki本文 = vector-search chunk
- `<page>...</page>` の明示参照だけを graph edge にする
- edge description は参照周辺の原文から機械的に作る
- LLM に entity / relation の抽出・分類・要約をさせない
- LightRAG workspace は正本ではなく、YAMLから再生成可能な派生物として扱う
- importer は前回同期stateを保持し、2回目以降は差分だけ更新する

## ファイル

- `build_gmodwiki_kg.py`
- `import_gmodwiki_kg.py`

builder の出力:

- `manifest.json`
- `entities.jsonl`
- `chunks.jsonl`
- `relationships.jsonl`
- `unresolved-links.jsonl`

`unresolved-links.jsonl` は診断用で、LightRAG には投入しません。

## 1. corpus build

```powershell
uv run --with PyYAML --with tiktoken .\build_gmodwiki_kg.py `
  D:\Dropbox\Projects\wikiscraper\work\allpages-slim.yml `
  D:\Dropbox\Projects\wikiscraper\work\lightrag-corpus `
  --force
```

既定値:

- target chunk: 900 tokens
- hard max: 1200 tokens
- oversized block overlap: 80 tokens
- entity synopsis: 700 tokens
- tokenizer: `gpt-4o-mini`

短いAPIページは1ページ1chunkです。
長いページだけ、`<function>` / `<example>`、Markdown heading、段落の順で
構造を優先し、それでも大きいブロックだけtoken windowで分割します。

## 2A. すでに旧 importer で全件投入済みの場合

今回の更新前の `import_gmodwiki_kg.py` で、現在の corpus をすでに
workspace に全件投入してある場合は、再embeddingせずbaselineだけ作れます。

```powershell
uv run --with "lightrag-hku[api]" .\import_gmodwiki_kg.py `
  D:\Dropbox\Projects\wikiscraper\work\lightrag-corpus `
  --workspace gmodwiki `
  --adopt-current
```

`--adopt-current` は LightRAG を変更しません。
「現在の workspace はこの corpus と一致している」と明示的に採用して、
次回更新から比較するstateを作るだけです。

## 2B. fresh workspace への初回投入

```powershell
uv run --with "lightrag-hku[api]" .\import_gmodwiki_kg.py `
  D:\Dropbox\Projects\wikiscraper\work\lightrag-corpus `
  --workspace gmodwiki `
  --full
```

初回投入中は embedding 件数、経過時間、ETA を表示します。

## 3. 以後の通常更新

Wikiを再scrapeして corpus を再buildした後、同じコマンドを
`--full` / `--adopt-current` なしで実行します。

```powershell
uv run --with "lightrag-hku[api]" .\import_gmodwiki_kg.py `
  D:\Dropbox\Projects\wikiscraper\work\lightrag-corpus `
  --workspace gmodwiki
```

importer は前回stateと新corpusを比較し、

- 新規・変更 chunk だけ embedding/upsert
- 新規・変更 entity だけ create/edit
- 新規・変更 relationship だけ create/edit
- 消えた relationship / entity / chunk を削除
- 完全に同一のものは何もしない

という同期を行います。

実行前に差分件数を表示し、各phaseとembeddingの進行状況も表示します。

計画だけ見る場合:

```powershell
uv run --with "lightrag-hku[api]" .\import_gmodwiki_kg.py `
  D:\Dropbox\Projects\wikiscraper\work\lightrag-corpus `
  --workspace gmodwiki `
  --dry-run
```

## State

既定では次に保存されます。

```text
<LightRAG WORKING_DIR>/.gmodwiki-import-state/<workspace>.json
```

state は正本ではなく、前回の同期済みオブジェクト集合を表す差分計算用データです。
更新の全mutationが成功した後にだけatomic replaceされます。

途中失敗した場合はstateを進めないため、次回実行で同じ差分を再試行します。

## LightRAG server との同時実行

ローカルの Json / NetworkX / NanoVectorDB storage を同じ working directory で
使う場合、書き込みimport中は `lightrag-server` を停止してください。

`--adopt-current` と `--dry-run` はLightRAG storageへ書き込みません。

## LLM

importer は custom-KG 同期中にLLMを使いません。
LLM呼び出しが発生した場合は意図しない経路として即座に失敗します。

embedding 設定は `lightrag-server` と同じ `.env` を読み、
LightRAG 自身の `create_embedding_function_from_args()` を使用します。
