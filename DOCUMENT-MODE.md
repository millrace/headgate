# headgate document mode — design

**Goal: let users drop a folder of their own files — PDFs, Word docs, text,
emails — and ask questions about them, with the same guarantee headgate gives
today: a frontier model writes the code, your content never leaves the machine.**

Today headgate v1 is built end to end around a **single CSV table**
(`schema.mojo` even says *"v1 reads CSV"*). The CSV is not a config detail — it's
the spine of the confidentiality model. This doc is the design for replacing that
spine with a **document set** while keeping the two guarantees intact.

---

## 1. Why this is a redesign, not a config flag

headgate's confidentiality trick (README): the model is allowed to see the
*shape* of the data — an **aliased schema** (`col_0`, `col_1`, types) plus
**synthetic rows** — and writes code against that shape. The code runs locally
over real values. This works because, for a table, **the shape is safe to share
and only the values + names are sensitive.**

Documents break that split:

| | CSV (today) | Documents |
|---|---|---|
| sensitive | cell values + column names | **the content itself** (prose, numbers, names) |
| safe to share | column names→aliases, types, row count | file types, counts, lengths (metadata only) |
| "schema" | columns + dtypes | (free-form: none) / (semi-structured: fields) |
| debugging fakes | synthetic rows | synthetic *documents* |

So there's no column schema to alias, and the sensitive part — the text — is
exactly what the model must **not** see. Every CSV-specific site has to be
re-expressed over a document abstraction:

- `schema.mojo`: `_find_csv`, `SchemaSanitizer.sanitize`, `fingerprints_from_csv`,
  `synthetic_csv`, `csv_path_for`, `inject_data_path` (`__DATA_CSV__`).
- `orchestrator.mojo`: the prompt *"reads the CSV at `__DATA_CSV__` … refer to
  columns by their aliases"*, the `synthetic.csv`, the real-path injection.
- `wiring.mojo` / `headgate.mojo` / `server.mojo`: `has_csv`, `_resolve_data_dir`,
  `seed_demo`.

The **sandbox** (`sandbox.mojo`) already read-scopes the whole `data_dir`, so
containment generalizes for free.

---

## 2. The one scoping decision that makes it tractable

Documents tempt a task headgate **cannot** safely serve via the remote model:
*"summarize this contract."* Summarizing requires the model to **read the
content** — which is the thing we're protecting. So we split tasks by who needs
to see the bytes:

- **Structural / extractive / aggregate tasks → remote codegen.** "How many
  invoices mention late fees?", "list every date", "total of all amounts",
  "which docs reference Acme?" — answerable by code that scans text it was never
  shown. The model writes that code blind, against the manifest + synthetic docs.
- **Content-understanding tasks → the LOCAL model only.** "Summarize each
  contract", "what's the gist?" — handled by the on-device trusted model (the
  existing `use_local_summary` path, which may see real data because it talks
  only to `127.0.0.1`). Never the remote model.

headgate should detect/declare this boundary and route accordingly, rather than
silently shipping content. **This distinction is the heart of the design** — it's
what lets a frontier model help with documents it isn't allowed to read.

---

## 3. The document pipeline

Mirror the CSV flow (sanitize → codegen → synthetic-debug → real-run), over a
document abstraction:

```
folder of files                                    answer (local)
   │                                                   ▲
   ▼ (1) LOCAL extract (trusted)                       │
DocumentSet: [ {id, real_path, type, text, len} … ]    │
   │                                                    │
   ▼ (2) sanitize → DocManifest (aliased ids/types/lens)│
   │            + synthetic corpus (fake docs)          │
   ▼ (3) remote codegen: "process the documents…"  ─────┤ egress guard
   │       (sees manifest + fakes; never real text)     │ (real text spans + canaries)
   ▼ (4) synthetic-debug loop (compile+run on fakes)    │
   ▼ (5) dealias + point at REAL extracted text ────────┘
         run in sandbox (network-deny) → result stays local
```

### (1) Extraction — a LOCAL, trusted step

Normalize every file to plain text + metadata **on-device, before anything is
shared**. Extraction is *trusted* (like the inference server's weight
downloader), so it can use mature libraries — it is **not** the sandboxed
generated code:

- `.txt` / `.md` → read directly (the trivial first slice).
- `.pdf` → text extraction (e.g. poppler `pdftotext`, or a Python lib like
  `pypdf` / `pdfminer` at the local step). Scanned/image PDFs (OCR) are out of
  scope v1.
- `.docx` → unzip + parse `word/document.xml` (or `python-docx`).
- later: `.html`, `.eml`.

Output: a normalized text cache (e.g. `~/.config/headgate/cache/<run>/doc_0.txt`)
plus a `DocumentSet` in memory. Unsupported/garbled files are skipped and
reported, never silently dropped.

### (2) Sanitize → DocManifest + synthetic corpus

The shareable view the remote model is allowed to see:

- **DocManifest**: aliased doc ids (`doc_0`…), `file_type`, `char_len`, and —
  for *semi-structured* docs only (invoices, forms) — an aliased **field schema**
  (`field_0: date`, `field_1: amount`), reusing today's alias machinery.
- **Synthetic corpus**: `n` fake documents matching the type/length
  distribution (templated/lorem text, fake fields), generated locally. The
  analog of `synthetic_csv`. Real text never appears.

**Leaked metadata (accept, document it):** file count, types, and approximate
lengths cross the gate. That's content-free and consistent with the
careful-SaaS posture — but it must be stated, not hidden.

### (3) Codegen

New system prompt, e.g.:

> *Write a Mojo program that reads the text documents listed in the manifest
> (one file per `doc_i`) from `__DATA_DIR__` and prints the result. Refer to
> documents by their aliases. You will not see the real text; debug against the
> synthetic corpus.*

Every outbound message still passes the **EgressGuard**.

### (4) Synthetic-debug loop

Unchanged in shape: compile **and** run the generated code against the
**synthetic** corpus dir; feed scrubbed errors back; iterate. Errors carry only
fake content.

### (5) Real run

Dealias (doc-id and any field aliases → real) and point `__DATA_DIR__` at the
**real** extracted-text cache, locally; compile + run in the network-deny
sandbox; the result stays local (optionally summarized by the local model).

### Egress guard for text

Replace `fingerprints_from_csv` (cell values) with **text-span fingerprints**:
sentence- or n-gram-level spans of the real extracted text above a min length,
plus **canary** strings seeded into the real docs. Fails closed if a real span
or canary appears on the outbound path. (Naive substring matching is
defense-in-depth, not airtight — same honest stance as today.)

---

## 4. New abstractions (where the code goes)

- `extract.mojo` (new): `extract(path) -> Document` per file type; the trusted
  local extraction layer. Pluggable by extension.
- `Document` / `DocumentSet`: `{ id, real_path, file_type, char_len, text }`
  (text is local-only). Replaces the implicit "one CSV".
- `DocManifest`: the shareable, aliased view (`aliased_json()` analog) +
  `synthetic_docs(n)` (the `synthetic_csv` analog).
- `inject_data_dir(code, dir)`: `__DATA_DIR__` placeholder (replaces
  `__DATA_CSV__`).
- EgressGuard: `fingerprints_from_text(...)` + canary support.

**CSV becomes one extractor.** A `.csv` is just a structured document; the
existing `SchemaSanitizer` is the CSV-shaped specialization of the general
manifest. Keeping CSV working through the new abstraction is the migration test.

---

## 5. Phased roadmap

| phase | delivers |
|---|---|
| **0 — Abstraction** | `Document`/`DocumentSet` + `DocManifest`; route the existing CSV path through it (CSV = one extractor). No behavior change; proves the seam. |
| **1 — Text docs** | `.txt`/`.md` extraction → full doc pipeline end to end (manifest + synthetic text docs + "process these files" codegen). The smallest real proof. |
| **2 — PDF** | the headline: local PDF→text extraction; multi-file folders. |
| **3 — docx (+ html/eml)** | unzip/XML extraction. |
| **4 — Semi-structured fields** | derive + alias fields for invoices/forms; richer synthetic; closer to the CSV experience. |
| **5 — Text egress guard** | sentence/n-gram fingerprints + canary injection into docs. |

Risk-ordered: phase 1 proves the confidentiality model survives the move to
unstructured data **before** investing in parsers.

---

## 6. Open questions / risks

1. **Extraction trust + robustness.** Extraction is local/trusted so it may use
   Python libs — but malformed PDFs must fail gracefully, not crash the run.
   In-process Mojo vs a local Python helper is a real choice (lean: local helper,
   like the engine's downloader).
2. **What "structure" is safe to expose.** Lengths + types are content-free;
   section headers or field *names* may leak (a header `Project Titanfall
   Revenue` is sensitive). Default conservative: ids/types/lengths only; opt-in
   field schema for semi-structured docs.
3. **Task routing.** Reliably classifying "extractive (remote-OK)" vs
   "needs-to-read (local-only)" is itself hard; when unsure, fail safe to local.
4. **Synthetic fidelity.** Fake docs must be structurally close enough
   (encoding, layout, field presence) that code debugged on them works on the
   real ones.
5. **Scanned PDFs / OCR, images, spreadsheets-as-docs** — out of scope v1; call
   it out so users aren't surprised.

---

## 7. What stays the same

The two guarantees (containment + confidentiality), the sandbox, the
budget-with-local-fallback, the orchestrator's sanitize→debug→run loop shape,
and the alias/dealias + synthetic-debug mechanism. Document mode generalizes the
*data layer* under that machinery — it doesn't change the harness's spine.
