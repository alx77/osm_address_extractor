# Improvement Plan: Vandalism Detection & Multi-Source Validation

---

## Phase 1 — Simple, High-Impact (no ML, no GPU)

### 1.1 Language-priority name selection (SQL change)

**Problem:** vandals can overwrite `name` while `name:XX` tags remain intact.  
**Fix:** in `osm_addresses_extractor.sql`, replace bare `name` with a COALESCE chain ordered by country language priority.

```sql
-- Example for UA:
COALESCE(
    tags->'name:uk',
    name,
    tags->'name:ru',
    tags->'name:en'
) AS name
```

Define per-country priority lists in a config file (`config/languages.yml`).  
**Effort:** 1 day. **Coverage:** protects against the most common vandalism pattern.

---

### 1.2 Diff-based change detection (schema + SQL)

**Problem:** `object_registry` stores stable `internal_id` but never tracks what the name *was*.  
**Fix:** add `name_hash` (md5 of name + name:* tags) and `last_changed` to `object_registry`. On each extraction, compare hashes — flag rows where name changed.

```sql
ALTER TABLE object_registry ADD COLUMN name_hash text;
ALTER TABLE object_registry ADD COLUMN last_changed timestamptz;
```

On restore: if `name_hash` differs → write to `validation_flags(osm_id, flag_type='name_changed', old_hash, new_hash, detected_at)`.  
**Effort:** 1–2 days. **Coverage:** catches any name mutation between extractions.

---

### 1.3 `validation_status` + `validation_score` columns

**Problem:** no way for downstream consumers to know data quality.  
**Fix:** add to `city`, `street`, `natural_feature` (buildings less critical):

```sql
validation_status  smallint  -- 0=ok, 1=suspect, 2=rejected
validation_score   real      -- 0.0–1.0, lower = more suspicious
```

SQL rules to populate on extraction:
- `LENGTH(name) < 3` → suspect
- `name` contains emoji or non-printable chars → suspect
- `name` has no alphabetic chars → reject
- city with 0 streets after extraction → suspect

**Effort:** 1 day.

---

### 1.4 Wikidata cross-validation for cities (Python script)

**Problem:** Wikidata already contains canonical names on 100+ languages, currently used only for `importance`.  
**Fix:** after imposm3 import, run a Python script that:
1. Reads cities with `wikidata` tag from `import.osm_admin.tags`
2. Fetches canonical names from Wikidata SPARQL
3. Compares: if `edit_distance(osm_name, wikidata_name) / len(wikidata_name) > 0.3` → flag
4. Writes flags to `validation_flags`
5. Optionally patches `name` from Wikidata for high-confidence matches

Wikidata SPARQL is free, no API key needed.  
**Effort:** 2–3 days. **Coverage:** ~80% of cities with population > 10k have Wikidata entries.

---

### 1.5 fastText language detection on `name:XX` tags (Python, CPU)

**Problem:** `name:uk` might contain Latin text after vandalism; `name:ru` might be empty while neighbors have it.  
**Fix:** run [fastText lid.176.bin](https://fasttext.cc/docs/en/language-identification.html) (126 MB, CPU-only) on all `name:XX` values:
- `name:uk` detected as non-Ukrainian → flag
- `name:ru` detected as non-Russian → flag
- Neighbor cities (within 100 km) have `name:en`, target does not → flag missing translation

No GPU needed, processes 1M strings/min on CPU.  
**Effort:** 1–2 days.

---

### 1.6 Extend `alias_osm` pattern to other sources

**Problem:** schema supports multiple sources (`data_source` table, `source_id` FK) but only OSM is wired.  
**Fix:** add tables `alias_wikidata` and `alias_geonames` mirroring `alias_osm` structure (wikidata_id/geonames_id → `internal_id`). Populate during Wikidata cross-validation (1.4).  
**Effort:** 0.5 days. **Benefit:** enables future cross-source joins without schema changes.

---

### 1.7 GeoNames as fallback name source

**Problem:** for objects without Wikidata entry, no external reference exists.  
**Fix:** download GeoNames `allCountries.txt` (1.5 GB, free). Index by coordinates. For flagged objects (from 1.3/1.5), do spatial lookup (nearest GeoNames entry within 5 km, same feature class) and compare name.  
**Effort:** 2 days.

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

**Model:** `Helsinki-NLP/opus-mt-*` family (per language pair, ~300 MB each) or `facebook/nllb-200-distilled-600M`.

**Approach:** for cities where multiple `name:XX` tags exist, translate `name:uk` → `name:en` and compare with actual `name:en`. High divergence → flag. Catches: `name:en` replaced by vandal while `name:uk` intact (or vice versa).  
**Effort:** 3–4 days.

---

### 2.3 Spatial Graph Neural Network for regional consistency (P40)

**Model:** GraphSAGE or GAT (PyTorch Geometric).

**Graph construction:**
- Nodes: cities + streets, features = name embedding + place type + population + coordinates
- Edges: spatial neighbors within 50 km (cities) or 1 km (streets)

**Task:** node-level anomaly detection — predict expected name embedding from neighbors; high prediction error → anomaly.

**Training data:** clean historical extractions as positive examples; synthetic vandalism (random name substitutions) as negative.

**Effort:** 2–3 weeks. Apply only to objects already flagged by Phase 1 (reduces graph size ~10x).

---

### 2.4 Autoencoder anomaly detection for address formats (P40)

**Model:** lightweight MLP autoencoder trained per country.

**Features per building:**
- housenumber format (numeric/alpha/mixed, length)
- distance to nearest street
- number of neighbors on same street
- street name length, language

**Training:** normal data from verified countries/cities. High reconstruction error → anomaly (unusual housenumber format, isolated address, etc.).  
**Effort:** 1 week.

---

### 2.5 Continuous learning feedback loop

**Prerequisite:** phases 1 + 2.1 running.

**Flow:**
1. Flagged objects → human review queue (simple web UI or spreadsheet export)
2. Reviewer marks: confirmed vandalism / false positive / unclear
3. Confirmed cases → fine-tune embedding model (2.1) with contrastive loss
4. False positives → adjust thresholds per country/region
5. Re-run validation on next extraction cycle

**Effort:** 2–3 weeks (including review UI).

---

## Implementation Order

| # | Task | Effort | Dependencies |
|---|------|--------|--------------|
| 1 | Language-priority name selection (1.1) | 1d | — |
| 2 | `validation_status`/`score` columns (1.3) | 1d | — |
| 3 | Diff-based change detection (1.2) | 2d | — |
| 4 | fastText language detection (1.5) | 2d | — |
| 5 | Wikidata cross-validation (1.4) | 3d | — |
| 6 | `alias_wikidata` table (1.6) | 0.5d | 1.4 |
| 7 | GeoNames fallback (1.7) | 2d | 1.6 |
| 8 | Multilingual embedding outlier (2.1) | 5d | 1.3, 1.5 |
| 9 | Cross-lingual consistency (2.2) | 4d | 2.1 |
| 10 | GNN regional validation (2.3) | 3w | 2.1 |
| 11 | Autoencoder address formats (2.4) | 1w | 1.3 |
| 12 | Feedback loop (2.5) | 3w | 2.1, 2.2 |
