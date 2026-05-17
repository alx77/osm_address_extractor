# Improvement Plan: Vandalism Detection & Multi-Source Validation

---

## Phase 1 — Simple, High-Impact (no ML, no GPU)

### ✅ ST_Covers fix for city-states (bonus fix)

**Problem:** `ST_Contains(A, A)` returns false in PostGIS, so city-states whose polygon equals
their state polygon (Berlin, Wien, Brussels…) silently fell out of the city table and were
recovered only via a hardcoded name list.  
**Fix:** replaced `ST_Contains` with `ST_Covers` in the city extraction join. Removed the
hardcoded `Berlin/Hamburg/Bremen` fallback — now universal.  
**Commit:** `fix: use ST_Covers for city extraction to handle city-states`

---

### ~~1.1 Language-priority name selection~~ — DROPPED

Discussed and rejected: `name` in OSM already reflects local usage correctly (e.g. Russian is
a native language in Ukraine, not an inconsistency). Applying a country→language priority would
be prescriptive and wrong. `name:XX` fallback does not reliably protect against vandalism either
— a vandal who changes `name` can just as easily change `name:uk`.

---

### ✅ 1.2 Diff-based change detection

**Implemented in `restore.sh`:**
- Before any DELETE/partition-drop, captures `(osm_id, name)` for city + state + street into a
  staging table (streets captured early because their partition is dropped next).
- For `natural_feature`: compares staged dump vs production before `ON CONFLICT DO NOTHING`
  discards changed names.
- After restore: joins prev names against new data by `osm_id`, inserts
  `name_changed / name_deleted / name_added` flags into `validation_flags`.
- Index on staging table `osm_id` to avoid hash-join spill on large countries (DE).

**Schema:** `validation_flags(id, internal_id, country_code, source, flag_type, old_value, new_value, detected_at)`  
**Commit:** `feat: diff-based name change detection via validation_flags`

---

### ✅ 1.3 `validation_status` + `validation_score` columns

**Added to:** `state`, `city`, `street`, `natural_feature` (buildings skipped — less critical).

Rules in `validate.sql` (worst wins):
- `NOT (name ~ '[[:alpha:]]')` → status=2 (rejected), score=0.0
- `LENGTH(name) < 3` or control chars → status=1 (suspect), score=0.5
- city with no streets → status=1 (suspect), score=0.5

Defaults: status=0, score=1.0.  
**Commit:** `feat: add validation_status and validation_score to state/city/street/natural_feature`

---

### ✅ 1.4 Wikidata cross-validation for cities

**Implemented in `validate.sql`** — no external API calls needed.

Uses the existing `wikimedia-importance.sql.gz` dump (already downloaded for importance scoring).
The `wikipedia_article.title` field contains the canonical city name in the given language.
Cities whose OSM name diverges from the Wikipedia title by >30% (levenshtein / max length) are
flagged (`source='wikidata'`, `flag_type='name_changed'`).

`wikipedia_article` is kept alive until after ID assignment so that `internal_id` is available
in the flags. Dropped at end of `validate.sql`.  
**Commit:** `feat: Wikidata name validation using existing wikipedia_article dump`

---

### ✅ 1.5 fastText language detection on `name:XX` tags

**Implemented as `fasttext_validator.py`** — standalone script, runs post-restore on host.

- Downloads `lid.176.bin` (126 MB) once to `./cache/`.
- Checks `name:XX` tags on city and state rows: if fastText detects a different language than
  `XX` with confidence ≥ 0.7 (and name ≥ 5 chars), flags as `name_lang_mismatch`.
- `old_value = tag key` (e.g. `name:uk`), `new_value = detected lang + confidence` (e.g. `ru (0.94)`).

No GPU required (~1M strings/min on CPU).  
**Usage:** `./fasttext_validator.py UA DE PL`  
**Requires:** `pip install fasttext psycopg2`  
**Commit:** `feat: fastText language detection for name:XX tags`

---

### 1.6 Extend `alias_osm` pattern to other sources — SKIPPED

Discussed and deferred: Natural Earth is largely redundant with GeoNames; Who's on First adds
OSM concordances but GeoNames + spatial joins already cover the use case. Will revisit if
a second external source is actively integrated.

---

### ✅ 1.7 GeoNames cross-validation

**Implemented in `extract.sh` + `validate.sql`.**

Downloads per-country GeoNames zip (`UA.zip`, `DE.zip` etc., 5–20 MB) with 30-day cache.
Loads populated places and admin areas into an UNLOGGED `geonames` table with a GiST index.

In `validate.sql`: LATERAL nearest-neighbor join (within 10 km), flags cities where names
diverge by >35% (`source='geonames'`). Complements Wikidata: small cities without Wikidata
entries often have a GeoNames record.

Table dropped at end of `validate.sql`; excluded from `pg_dump`; cleaned up in `SKIP_VALIDATION` path.  
**Commit:** `feat: GeoNames cross-validation for city names`

---

### ✅ Validation phase refactor

All validation logic extracted from `osm_addresses_extractor.sql` into **`validate.sql`**.  
Set `SKIP_VALIDATION=1` to bypass the phase entirely (useful for debugging, faster re-runs).  
`lang_primary` (ISO 639-1, derived from country code) passed as psql variable to both scripts.  
**Commit:** `refactor: extract validation phase into separate validate.sql`

---

## Phase 2 — Complex, High-Impact (ML, GPU)

### 2.1 Multilingual embedding outlier detection (P40)

**Model:** `paraphrase-multilingual-mpnet-base-v2` (420 MB, ~100k objects/min on P40).

**Approach:**
1. Embed all city/street `name` values as vectors
2. For each object, compute cosine similarity against K nearest neighbors (spatial, same admin level)
3. Objects whose name embedding is far from the regional cluster → anomaly score
4. Threshold → `validation_flags`

Works for: subtle name corruption, wrong-language substitution, invented names.  
**Effort:** 3–5 days.

---

### 2.2 Cross-lingual translation consistency check (P40)

**Model:** `Helsinki-NLP/opus-mt-*` family or `facebook/nllb-200-distilled-600M`.

For cities where multiple `name:XX` tags exist, translate `name:uk` → `name:en` and compare
with actual `name:en`. High divergence → flag.  
**Effort:** 3–4 days.

---

### 2.3 Spatial Graph Neural Network for regional consistency (P40)

**Model:** GraphSAGE or GAT (PyTorch Geometric).

- Nodes: cities + streets; features = name embedding + place type + population + coordinates
- Edges: spatial neighbors within 50 km (cities) or 1 km (streets)
- Task: predict expected name embedding from neighbors; high error → anomaly

Apply only to objects already flagged by Phase 1 (reduces graph size ~10×).  
**Effort:** 2–3 weeks.

---

### 2.4 Autoencoder anomaly detection for address formats (P40)

Lightweight MLP autoencoder per country. Features: housenumber format, distance to street,
neighbor count, street name length. High reconstruction error → unusual address pattern.  
**Effort:** 1 week.

---

### 2.5 Continuous learning feedback loop

**Prerequisite:** Phase 1 + 2.1 running.

1. Flagged objects → human review queue
2. Reviewer marks: confirmed / false positive / unclear
3. Confirmed → fine-tune embedding model (contrastive loss)
4. False positives → adjust thresholds per country/region

**Effort:** 2–3 weeks (including review UI).

---

## Implementation Status

| # | Task | Status | Notes |
|---|------|--------|-------|
| — | ST_Covers city-state fix | ✅ Done | Universal, replaces hardcoded DE list |
| 1.1 | Language-priority name selection | ❌ Dropped | Approach invalid; `name` reflects local usage |
| 1.2 | Diff-based change detection | ✅ Done | In `restore.sh`, covers city/state/street/natural_feature |
| 1.3 | `validation_status`/`score` columns | ✅ Done | In `validate.sql`, 4 tables |
| 1.4 | Wikidata cross-validation | ✅ Done | Uses existing dump, no API calls |
| 1.5 | fastText language detection | ✅ Done | `fasttext_validator.py`, post-restore |
| 1.6 | `alias_wikidata` table | ⏸ Skipped | Deferred; GeoNames covers the use case |
| 1.7 | GeoNames cross-validation | ✅ Done | In `validate.sql`, 10 km nearest-neighbor |
| — | Validation phase refactor | ✅ Done | `validate.sql`, `SKIP_VALIDATION=1` flag |
| 2.1 | Multilingual embedding outlier | ⬜ Todo | |
| 2.2 | Cross-lingual consistency | ⬜ Todo | |
| 2.3 | GNN regional validation | ⬜ Todo | |
| 2.4 | Autoencoder address formats | ⬜ Todo | |
| 2.5 | Feedback loop | ⬜ Todo | |
