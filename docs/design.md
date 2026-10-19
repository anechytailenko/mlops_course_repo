# Design document: Guardian news section classifier

| | |
|---|---|
| Course | KSE MLOps — Introduction to MLOps and ML System Design |
| Use case | Dynamic news classification (Lab 1, Appendix 1) |
| Data source | The Guardian Open Platform Content API |
| Status | Lab 1 — first version |
| Template | [eugeneyan/ml-design-docs](https://github.com/eugeneyan/ml-design-docs) |

Statements marked **Assumption:** are decisions taken without confirmed facts. Each one names what will confirm or replace it.

---

## 1 Overview

Newsrooms file every article under a section (politics, business, sport, culture, …), and doing it by hand is slow and inconsistent, while topics and vocabulary change every week. We build a system that suggests the section of a news article from its text and from metadata known at publication time, using full-text articles from The Guardian Open Platform API as both training data and the live stream. The system collects new articles daily, validates and versions them, keeps per-author and per-office features in a feature store, trains and registers models, serves predictions through an API and a daily batch, and monitors drift so that it retrains when quality degrades. The desired outcome is a reproducible pipeline whose suggestions an editor accepts for at least 85% of articles and which detects its own degradation without waiting for a person to notice.

---

## 2 Motivation

**Who consumes the predictions.**
- *Editorial desk (primary).* When an article is ready, the CMS asks the system for a suggested section and shows the top 3 to the editor. In this project the CMS is emulated by a client script (`cms-client`) that replays newly published Guardian articles.
- *Newsroom analytics (secondary).* A daily table of predicted sections for all articles of the previous day, used for topic-volume reports and for monitoring.

**How often.** Continuously during the day, one request per new article. Assumption: ~250 articles/day, to be confirmed by `response.total` of the first API call (see 5.2).

**What happens when a prediction is wrong.** The editor corrects the section by hand (Assumption: ~30 s per correction). If nobody notices, the article lands on the wrong section front and in the wrong newsletter, and loses audience. A wrong suggestion is cheap one at a time but expensive when it is systematic, for example when a new topic appears and the model keeps sending it to `world`.

**Why a system and not a notebook.** News changes continuously: new events bring new vocabulary, sections are reorganised, the label mix shifts with the news cycle. A model trained once in a notebook degrades silently. During dataset selection, a TF-IDF + logistic regression baseline trained on 2014–2015 HuffPost headlines fell from macro-F1 0.617 (2016) to 0.465 (first half of 2018) with no code change. The value here is in the loop around the model: periodic collection, validation, versioning, monitoring for degradation, and retraining by trigger.

---

## 3 Success metrics

Three layers, kept apart. A model can improve while the business metric does not, and the reverse.

| Layer | Metric | Target | Role | How it is measured |
|---|---|---|---|---|
| Business | **Suggestion acceptance rate**: share of articles where the top-1 suggestion equals the section the editor finally keeps | ≥ 85% (Assumption, revised after Lab 2 baseline) | Decision metric | Emulated: top-1 prediction vs Guardian's editorial `sectionId` after the 24 h label delay |
| Business | **Top-3 coverage**: final section is among the 3 suggestions | ≥ 95% (Assumption) | Secondary | Same data as above |
| Model | **Macro-F1** on the most recent fully labelled time window | ≥ 0.80 and ≥ baseline + 0.10 (Assumption) | **Optimizing** | Offline on the held-out period (5.4); online daily once labels arrive |
| Model | Per-class recall | ≥ 0.60 for every class | **Satisficing** | Same evaluation |
| System | p95 latency of `POST /classify` | ≤ 300 ms | **Satisficing** | Prometheus histogram |
| System | Data freshness: previous day ingested, validated and in the feature store | by 06:00 UTC daily | **Satisficing** | Airflow run timestamps; age of newest row in the online store |
| System | API availability | ≥ 99% during the demo window (Assumption: local single-replica deployment) | **Satisficing** | Prometheus `up` and probe results |

Macro-F1 is the optimizing metric because classes are imbalanced (sport and world dominate) and every section matters to its editor. All other metrics are thresholds that a model must satisfy, not maximise.

---

## 4 Requirements and constraints

### Functional requirements

| # | Requirement |
|---|---|
| F1 | Ingest all articles published in the previous UTC day from the Guardian Content API (`type=article`, full text, tags, fields) and store the raw responses unchanged. |
| F2 | Validate every batch (schema, volume, nulls, duplicates, unmapped sections) and stop the pipeline on failure. |
| F3 | Map Guardian `sectionId` to the project label set through a versioned mapping file. |
| F4 | Compute features per entity (contributor, production office) with event timestamps; publish them to the offline store and materialise the latest values to the online store. |
| F5 | Train a baseline and a candidate model on a time-based split; log parameters, metrics, data version and commit; register the model. |
| F6 | **Online inference.** `POST /classify` accepts `{headline, standfirst, body_text, contributor_ids[], production_office, published_at}` and returns `{section, confidence, top3[], model_version, fallback_used}`. Caller: the CMS (emulated by `cms-client`). |
| F7 | **Batch inference.** Every day, score all articles of the previous day into the `predictions` table in PostgreSQL. Caller: Airflow; reader: newsroom analytics and monitoring. |
| F8 | Monitor inputs, predictions and (after the delay) labels; raise an alert when a threshold is crossed; trigger retraining. |

### Non-functional requirements

| Category | Requirement |
|---|---|
| **Freshness** | Previous day's articles ingested, validated and materialised to the online store by 06:00 UTC. Online features are at most 30 h old (24 h label delay + 6 h pipeline window); older values are treated as missing. |
| **Latency and throughput** | `POST /classify` p95 ≤ 300 ms, p99 ≤ 800 ms. Sustained 1 request/s, bursts of 5 requests/s. Assumption: ~250 articles/day, peaks of ~30/hour. Daily batch scoring of one day ≤ 10 min. |
| **Availability and fallback** | API ≥ 99% during the demo window. If the model cannot be loaded, the service answers with the rule-based keyword baseline and sets `fallback_used=true`. If the online store is unreachable or the contributor is unknown, the model uses default feature values (global class prior) instead of failing. If the Guardian API is down, ingestion retries for 6 h and then alerts; the last champion keeps serving. |
| **Reproducibility** | Any registered model can be rebuilt from its MLflow run: tags `git_commit`, `data_version` (DVC hash of the training snapshot), `section_map_version`, `feature_service`. `make setup` recreates the environment from `uv.lock`; `dvc pull` restores raw snapshots without a Guardian key. |
| **Adaptability** | New data enters daily as a new date partition. New models enter through scheduled weekly retraining or a drift-triggered run, as `@challenger`, and replace `@champion` only through the promotion gate (5.4) and a human approval (5.5). New Guardian sections enter through the versioned section map; until mapped they go to `other`. |
| **Observability without ground truth** | During the 24 h before labels arrive: predicted-class distribution vs the reference window, mean confidence and share of low-confidence predictions (< 0.5), text drift on TF-IDF features, share of `other` / unmapped sections, ingested volume per day, feature freshness. After labels: macro-F1 and acceptance rate per day and per 7-day window. |
| **Cost and resource ceilings** | Local stack fits in 8 GB RAM and 4 CPU cores (Minikube 4 GB + host services). Training on CPU only, ≤ 30 min per run. Guardian API usage ≤ 400 calls/day, which keeps 20% headroom under the most restrictive reported developer limit (500/day). Raw storage ≤ 5 GB. Monthly cloud cost: see 6.7. |

### In scope

- English Guardian articles of `type=article` from 2024-01-01 onwards, with full body text.
- Single-label classification into the project label set (5.1).
- Daily batch ingestion; online and batch inference; drift monitoring and retraining loop.
- Local deployment on the reference stack; cloud equivalents named, not deployed.

### Out of scope

- Live blogs, galleries, video, audio, interactives, crosswords (non-`article` types).
- Opinion pillar (`commentisfree`): opinion pieces span all topics and have their own editorial flow. Assumption: revisited after Lab 2 error analysis.
- Multi-label tagging with Guardian keyword tags; images and video.
- Languages other than English; sources other than the Guardian.
- Writing back to a real CMS; any commercial use of Guardian content.

---

## 5 Methodology

### 5.1 Problem statement

**Framing: single-label multi-class text classification.** Input: an article at publication time (headline, standfirst, body text, contributor ids, production office, publication time). Output: one of the project sections, with a probability per class.

**Label set.** Guardian `sectionId` values mapped to 12 classes by `configs/section_map.yaml` (versioned in Git):

| Class | Guardian `sectionId` values (initial mapping) |
|---|---|
| `world` | `world` |
| `uk-news` | `uk-news` |
| `us-news` | `us-news` |
| `politics` | `politics` |
| `business` | `business`, `money` |
| `technology` | `technology` |
| `science` | `science` |
| `environment` | `environment` |
| `sport` | `sport`, `football` |
| `culture` | `culture`, `film`, `music`, `books`, `tv-and-radio`, `artanddesign`, `stage`, `games` |
| `lifestyle` | `lifeandstyle`, `fashion`, `food`, `travel` |
| `other` | any section not listed above |

Assumption: the mapping is final only after counting `sectionId` frequencies over one month of real data; classes below 1% of volume are merged.

**Rejected framing: multi-label classification over Guardian keyword tags.** It would be closer to how the Guardian tags content, but keyword tag ids start with the section name (`football/premierleague`), so they leak the label. The label space is also thousands of tags with a long tail, and per-tag evaluation would be meaningless with our data volume. A second rejected option, the 5 `pillarName` values (News, Opinion, Sport, Arts, Lifestyle), is too coarse to be useful to an editor.

### 5.2 Data

**Source.** The Guardian Open Platform Content API, `https://content.guardianapis.com/search`. Owner: Guardian News & Media. Access: free developer key, non-commercial use; Guardian staff have confirmed that student projects are allowed.

**Request per batch.**
```
/search?from-date=D&to-date=D&use-date=published&type=article
       &order-by=oldest&page-size=200&page=N
       &show-fields=headline,standfirst,trailText,bodyText,byline,wordcount,
                    firstPublicationDate,lastModified,productionOffice,lang
       &show-tags=contributor,keyword,tone,series
       &api-key=$GUARDIAN_API_KEY
```

**Arrival pattern.** Articles are published continuously. The pipeline collects them as one daily batch per UTC day (`guardian_ingest_daily`, 03:00 UTC). A second query with `use-date=last-modified` picks up articles changed in the last 3 days, so corrections reach the raw layer.

**Volume.** Assumption: ~250 articles/day, ~1–3 calls/day. To be replaced by the measured `response.total` of a sample week.

**History.** Backfill 2024-01-01 → 2026-09-30 (33 months, Assumption: ~250k articles). Paged by month at 200 articles per call, that is ~1,300 calls, or about 4 days of runs capped at 400 calls/day.

**Labels and their delay.**
- The label is the editorial `sectionId`, mapped to the project class.
- In reality it arrives with the article. To emulate an editor confirming the section later, the system treats the label as **unavailable for 24 h** after `webPublicationDate`. Monitoring and contributor features may use it only after that.
- A label changes if the Guardian moves the article; the `last-modified` sweep records the change.

**Available at serving time vs training time.**

| Data | Training | Serving (at publication) |
|---|---|---|
| `headline`, `standfirst`, `bodyText`, `wordcount` | ✅ | ✅ in the request |
| Contributor tag ids, `productionOffice`, publication time, tone tag | ✅ | ✅ in the request |
| Contributor and office history features | ✅ point-in-time from the offline store | ✅ latest value from the online store (labels older than 24 h only) |
| `sectionId`, `sectionName`, `pillarName` | ✅ as **target only** | ❌ (that is what we predict) |
| `id`, `webUrl`, keyword / series / newspaper-section tags | ❌ excluded (leak the label) | ❌ |
| Later edits (`lastModified` > publication) | ❌ only the first-seen version is used for training | ❌ |

**Storage layers.**
- **raw:** JSON responses exactly as received, partitioned `raw/guardian/date=YYYY-MM-DD/page-N.json` in MinIO, immutable.
- **clean:** Parquet, one row per article (deduplicated by `id`, first-seen version), typed columns, mapped label, partitioned by `date=`.
- **features:** Parquet with `event_timestamp` per entity (Feast offline source), plus the PostgreSQL online store.
- **Versioning:** DVC tracks a snapshot of the raw and clean layers (`dvc add`), remote in the MinIO `dvc` bucket. The DVC hash is the data version.

**Dataset checklist (Lab 1, step 1).**

| Item | Justification |
|---|---|
| Time axis | Every article has `webPublicationDate` to the second; the API filters by `from-date`/`to-date`, so "next day" and "next month" batches are real requests, not a replay. New data keeps arriving, so Lab 4 can observe real drift as well as emulate it. |
| History to hold out a period | 33 months of backfill (2024-01 → 2026-09). Hold-out: 2026-04 → 2026-06 as test; 2026-07 → 2026-09 replayed as "production" months; live data after that (5.4). |
| Labels with known delay | Editorial `sectionId` on every article. Delay: 24 h, emulated as an editor confirmation window (Assumption, chosen to make monitoring without labels a real phase). |
| Text surface or corpus | Full article body text (`bodyText`, Assumption: median several hundred words). The same corpus is the document base for the Lab 3 retrieval component. |

### 5.3 Techniques

**Baseline first: rule-based keyword classifier.** For each class, a lexicon of 20–40 keywords is built once from training-period headlines (most discriminative terms, reviewed by hand). An article is assigned to the class with the most keyword hits in headline + standfirst, with ties going to the most frequent class. It needs no model file, runs in microseconds, and is the **production fallback** (4, Availability).

**Candidate: TF-IDF + logistic regression with metadata features** (scikit-learn).
- Text: headline, standfirst and the first 300 words of the body, word 1–2-grams, sublinear TF.
- Metadata: one-hot production office and tone tag, publication hour, log word count.
- Feature-store features: contributor and office history (below).
- One-vs-rest logistic regression with class weights.

It trains in minutes on CPU, is reproducible and is easy to explain. A transformer fine-tune is an alternative for later (7.1), not a requirement.

**Features and their serving-time source.**

| Feature | Entity | Computation | Training source | Serving source |
|---|---|---|---|---|
| `tfidf(headline + standfirst + body[:300])` | article | vectoriser fitted on the training window | clean Parquet | request body |
| `log_wordcount` | article | `log1p(wordcount)` | clean Parquet | request body |
| `pub_hour`, `pub_weekday` | article | from `published_at` | clean Parquet | request body |
| `tone` | article | tone tag (news, comment, interview, …) | clean Parquet | request body |
| `production_office` | article | one-hot UK / US / AUS | clean Parquet | request body |
| `contrib_class_share_30d[k]` | contributor | share of the contributor's articles in class k over the last 30 days, **labels older than 24 h only** | Feast offline store, point-in-time join | Feast online store, key = `contributor_id` |
| `contrib_articles_30d` | contributor | count over the last 30 days | Feast offline store | Feast online store |
| `office_class_share_7d[k]` | production office | class distribution over the last 7 days | Feast offline store | Feast online store, key = `production_office` |

For articles with several contributors, contributor features are averaged. An unknown contributor gets the global class prior and `contrib_articles_30d = 0`.

**Training/serving skew guard.** Text preprocessing and feature code live in one package imported by the training pipeline, the batch scorer and `classifier-api`. Contributor features are defined once as Feast feature views (`contributor_stats`, `office_stats`) and served through one Feast feature service (`section_classifier_v1`) for both training and serving.

### 5.4 Experimentation and validation

**Split strategy: time-based, never random.** News is ordered in time: the same story produces many near-duplicate articles over a few days, and vocabulary from a future event must not leak into training.

| Window | Period | Use |
|---|---|---|
| Train | 2024-01-01 → 2025-12-31 | Fit vectoriser and model |
| Validation | 2026-01-01 → 2026-03-31 | Hyperparameters, threshold choices |
| Test (held out) | 2026-04-01 → 2026-06-30 | Single final offline report per model version |
| Production replay | 2026-07-01 → 2026-09-30 | Lab 2 "next month" ingestion, Lab 4 drift emulation |
| Live | 2026-10 onwards | Real daily ingestion and monitoring |

**Leakage it prevents:**
- future events and vocabulary in training;
- the same story (or the same article in a later edited version) on both sides of the split, so articles are deduplicated by `id`, keeping the first-seen version;
- contributor statistics computed with labels from the future, which point-in-time joins and the 24 h label delay rule out;
- label leakage through URLs and keyword tags, which are excluded (5.2).

**Offline metric.** Macro-F1 on the test window, plus per-class recall and the confusion matrix. A rolling-origin check (train up to month M, test on M+1, for the last 6 months) measures how fast quality decays, which sets the retraining cadence.

**Comparing a new model with the current one.** Both models are scored on **the same most recent fully labelled window** (the last 14 days with labels). The challenger is promoted to `@champion` only if all of these hold:
1. macro-F1 ≥ champion + 0.01;
2. no class recall drops by more than 0.05;
3. p95 latency in a load test ≤ 300 ms;
4. it beats the keyword baseline by ≥ 0.10 macro-F1;
5. a human approves (5.5).

Results are logged to MLflow; the comparison report is attached to the challenger's run.

### 5.5 Human in the loop

| Situation | Who | Action and expected response time |
|---|---|---|
| Drift or quality alert | On-call ML engineer (in this project: the repository owner) | Receives a Grafana alert by e-mail and opens the Evidently report within 1 working day. Decides: ignore (news-cycle spike), update the section map, or start retraining. Decision logged in `docs/incidents.md`. |
| Model promotion | Model owner | Reviews the challenger-vs-champion report in MLflow and moves the `@champion` alias by hand. The automatic gate (5.4) only proposes. |
| Rollback | Model owner | Points `@champion` back to the previous version; `classifier-api` reloads on the next readiness check. |
| Override of a prediction | Editor (emulated) | Picks a different section in the CMS. The final section is stored as the label with `source=editor`, and the disagreement counts against the acceptance rate. |
| New Guardian section appears | Model owner | Adds it to `configs/section_map.yaml` (versioned). Until then it maps to `other`, which is monitored. |

---

## 6 Implementation

### 6.1 High-level design

#### System context

```mermaid
flowchart LR
  GU["The Guardian Open Platform API"] -->|"articles: full text, tags, fields"| SYS
  GU -->|"labels: editorial sectionId, after 24 h"| SYS
  SYS["Guardian news section classifier<br/>ingests, validates, trains,<br/>serves, monitors"]
  CMS["Editorial desk<br/>(CMS, emulated by cms-client)"] -->|"article at publication"| SYS
  SYS -->|"suggested section, top-3, confidence"| CMS
  SYS -->|"daily predictions table"| AN["Newsroom analytics"]
  SYS -->|"drift and quality alerts by e-mail"| OC["On-call ML engineer"]
  OC -->|"promotion approval, rollback, section map"| SYS
```

#### Data flow on the seven layers

```mermaid
flowchart TB
  subgraph L1["1 Data ingestion"]
    GAPI["Guardian Content API"] --> ING["Airflow DAG guardian_ingest_daily"]
    ING --> RAW[("MinIO raw/guardian/date=")]
  end
  subgraph L2["2 Preprocessing and transformation"]
    VER{{"VERSION POINT<br/>DVC snapshot of raw and clean"}}
    QG{{"QUALITY GATE<br/>validate_batch: schema, volume,<br/>nulls, duplicates, unmapped sections"}}
    CLEAN["clean_transform: dedupe by id, map labels,<br/>strip leaking fields"]
    CL[("MinIO clean Parquet")]
  end
  subgraph L3["3 Feature store: Feast"]
    OFF[("Offline store<br/>Parquet in MinIO features")]
    ON[("Online store<br/>PostgreSQL")]
  end
  subgraph L4["4 Training pipeline"]
    TRN["Airflow DAG train_classifier<br/>baseline + TF-IDF logistic regression"]
  end
  subgraph L5["5 Registry and deployment"]
    REG[("MLflow Registry<br/>news-section-classifier<br/>@champion / @challenger")]
  end
  subgraph L6["6 Inference"]
    API["classifier-api: POST /classify<br/>real-time"]
    BAT["Airflow DAG score_batch_daily<br/>batch"]
    PRED[("PostgreSQL predictions")]
  end
  subgraph L7["7 Monitoring and retraining loop"]
    MON["Airflow DAG monitor_daily<br/>Evidently reports"]
    PROM["Prometheus + Grafana<br/>metrics, dashboards, alerts"]
  end
  RAW --> QG
  QG -->|"pass"| CLEAN --> CL
  QG -->|"fail: stop and alert"| PROM
  RAW -.-> VER
  CL -.-> VER
  CL --> OFF
  OFF ==>|"TRAINING PATH<br/>point-in-time join"| TRN
  OFF ==>|"SERVING PATH<br/>materialize"| ON
  CL -->|"training text"| TRN
  TRN -->|"log run, register"| REG
  REG -->|"load @champion"| API
  REG -->|"load @champion"| BAT
  ON -->|"get_online_features"| API
  ON --> BAT
  CMSC["cms-client"] -->|"article"| API
  API -->|"section"| CMSC
  BAT --> PRED
  API -->|"inputs, predictions, latency"| PROM
  PRED --> MON
  CL -->|"labels after 24 h"| MON
  MON --> PROM
  PROM -->|"alert e-mail"| OCE["On-call ML engineer"]
  MON -->|"trigger retraining"| TRN
```

The three required marks:
1. **Version point:** DVC snapshot of the raw and clean layers. Every MLflow run is tagged with its hash.
2. **Quality gate:** `validate_batch`, before anything reaches the clean layer or the feature store.
3. **Where training and serving diverge:** the offline side of Feast feeds `train_classifier` through point-in-time joins; the online side, materialised to PostgreSQL, feeds `classifier-api` and `score_batch_daily`.

#### Deployment, first draft

```mermaid
flowchart TB
  subgraph DEV["Developer laptop: Docker Desktop"]
    subgraph COMPOSE["Docker Compose (Lab 2)"]
      MINIO["MinIO pgsty/silo<br/>→ S3 / Cloud Storage / Blob Storage"]
      PG["PostgreSQL 16<br/>→ RDS / Cloud SQL / Azure DB for PostgreSQL"]
      AF["Airflow 3.3.1 LocalExecutor<br/>→ MWAA / Cloud Composer / Data Factory"]
      MLF["MLflow 3.16.1<br/>→ SageMaker with MLflow / Vertex AI / Azure ML"]
      FEAST["Feast 0.66.0<br/>→ SageMaker FS / Vertex AI FS / Azure ML FS"]
    end
    subgraph MK["Minikube 1.33.1, Kubernetes 1.30.0 (Lab 4) → EKS / GKE / AKS"]
      CAPI["classifier-api: FastAPI + model<br/>image in Minikube registry → ECR / Artifact Registry / ACR"]
      MONS["Prometheus + Grafana<br/>→ CloudWatch / Cloud Monitoring / Azure Monitor"]
      EVI["Evidently reports<br/>→ SageMaker Model Monitor / Vertex AI Model Monitoring / Azure ML monitoring"]
    end
    DVCC["DVC 3.67.1 client, remote on MinIO<br/>→ S3 / GCS / Azure Blob remote"]
  end
  GH["GitHub: repository + Actions lint CI"]
  GAPI2["Guardian Content API (external)"]
  GAPI2 --> AF
  AF --> MINIO
  AF --> PG
  AF --> MLF
  AF --> FEAST
  FEAST --> PG
  FEAST --> MINIO
  MLF --> PG
  MLF --> MINIO
  DVCC --> MINIO
  CAPI --> PG
  CAPI --> MLF
  MONS --> CAPI
  GH -.->|"code"| DEV
```

### 6.2 Infra

| Component | Role in this system | Local (pinned) | AWS | GCP | Azure |
|---|---|---|---|---|---|
| Object storage | Raw JSON, clean and feature Parquet, MLflow artifacts, DVC remote | MinIO-compatible `pgsty/silo` (buckets `raw`, `clean`, `features`, `mlflow`, `dvc`) | Amazon S3 | Cloud Storage | Blob Storage |
| Data versioning | Snapshot of raw and clean layers; data version = DVC hash | DVC 3.67.1 + dvc-s3 3.3.0, remote on MinIO | S3 remote | GCS remote | Azure Blob remote |
| Database | Feast online store, MLflow backend, `predictions` table, Airflow metadata | PostgreSQL 16 | Amazon RDS | Cloud SQL | Azure Database for PostgreSQL |
| Orchestrator | DAGs `guardian_ingest_daily` (tasks `validate_batch`, `clean_transform`), `score_batch_daily`, `monitor_daily`, `train_classifier` | Apache Airflow 3.3.1, LocalExecutor | Amazon MWAA | Cloud Composer | Azure Data Factory |
| Tracking and registry | Runs, metrics, lineage tags; model `news-section-classifier` with aliases | MLflow 3.16.1 (PostgreSQL backend, MinIO artifacts) | SageMaker with MLflow | Vertex AI Experiments and Model Registry | Azure ML with MLflow |
| Feature store | Feature views `contributor_stats`, `office_stats`; feature service `section_classifier_v1` | Feast 0.66.0 (offline: Parquet in MinIO; online: PostgreSQL) | SageMaker Feature Store | Vertex AI Feature Store | Azure ML managed feature store |
| Model service | `classifier-api`: FastAPI, loads `@champion`, serves `POST /classify`, `/health`, `/ready`, `/metrics` | Container on Minikube | Amazon EKS | GKE | AKS |
| Container registry | Images of `classifier-api` tagged with the commit | Minikube built-in registry | Amazon ECR | Artifact Registry | Azure Container Registry |
| Kubernetes cluster | Runs serving and monitoring in Lab 4 | Minikube 1.33.1 (Kubernetes 1.30.0, docker driver, 4 GB) | Amazon EKS | GKE | AKS |
| Model and data monitoring | Text, prediction and label drift reports | Evidently | SageMaker Model Monitor | Vertex AI Model Monitoring | Azure ML model monitoring |
| Metrics and dashboards | Latency, throughput, freshness, alerts | Prometheus, Grafana | Amazon CloudWatch | Cloud Monitoring | Azure Monitor |
| Local runtime | Runs the Lab 2 services together | Docker Desktop + Docker Compose | — (replaced by the managed services above) | — | — |
| Code and CI | Repository, lint CI (tests from Lab 2) | GitHub + GitHub Actions | GitHub Actions (same) | GitHub Actions (same) | GitHub Actions (same) |
| External data source | Articles and labels | The Guardian Open Platform Content API | — | — | — |
| Consumer emulator | Replays new articles to `POST /classify` | `cms-client` Python script | — | — | — |

Lab 1 runs nothing but CI. Lab 2 starts MinIO, PostgreSQL, Airflow, MLflow and Feast with Docker Compose; Lab 4 moves serving and monitoring to Minikube. Lab 3 adds a vector store (pgvector or Qdrant) and an LLM; this table is revised then.

### 6.3 Performance

| Item | Budget | Basis |
|---|---|---|
| Online throughput | 1 req/s sustained, 5 req/s burst | Assumption: ~250 articles/day, peaks ~30/hour; editors may re-request on edits |
| Online latency | p95 ≤ 300 ms, p99 ≤ 800 ms end to end | TF-IDF + linear model ≈ few ms; online store lookup ≈ 10–20 ms; rest is network and JSON |
| Batch scoring | One day (~250 articles) ≤ 10 min, finished by 06:00 UTC | Runs after ingestion and materialisation |
| Training | ≤ 30 min on 4 CPU cores | ~180k training articles, sparse linear model |
| Ingestion | ≤ 3 API calls/day steady state; backfill ≤ 400 calls/day | Rate-limit headroom (4, cost row) |
| Storage | Raw ≤ 5 GB, clean Parquet ≤ 1 GB | Assumption: ~10 KB raw JSON per article incl. tags |

**Batch versus online: both, for different consumers.** The editorial desk needs the suggestion while the editor is filing the article, so a nightly batch would arrive too late; that path is online. Analytics and monitoring need every article of the day scored with the same model version, with labels joined later, and do not care about seconds; that path is a daily batch. Both paths load the same `@champion` and the same Feast feature service, so they cannot diverge.

### 6.4 Security

- **Secrets.**
  - `GUARDIAN_API_KEY`, MinIO and PostgreSQL credentials live in `.env`, which is git-ignored; `.env.example` with empty values is committed.
  - Airflow reads them as connections and variables; in Lab 4 they become Kubernetes Secrets.
  - CI needs no secrets in Lab 1. If later CI jobs need the Guardian key, it goes into GitHub Actions Secrets, never into a workflow file.
- **Who may call the service.** `classifier-api` is reachable only inside the Minikube cluster and through `kubectl port-forward`. Assumption: a static bearer token for `POST /classify` (from a Kubernetes Secret) is enough for the course. `/health` and `/metrics` stay unauthenticated inside the cluster.
- **Supply chain.** Dependencies are pinned in `uv.lock`; images are tagged with the commit hash; ruff runs in pre-commit and CI.
- **Guardian key protection.** Requests stay under the daily limit (4); on HTTP 403/429 the DAG backs off and alerts instead of retrying in a loop.

### 6.5 Data privacy

- **Personal data in the dataset.** Article texts are public journalism but mention named people. Bylines and contributor tags identify journalists, and the contributor id is used as a feature-store entity. No reader data, user accounts or behaviour logs are collected.
- **Minimisation.** Only the fields listed in 5.2 are requested; contributor emails, Twitter handles and bios in tag objects are dropped in the clean layer.
- **Retention.** Raw responses are kept for the course duration plus 3 months, then deleted. Assumption: storing article text for non-commercial research is within the Open Platform terms; to be confirmed when the key is issued. Feature-store rows keep only aggregates (counts and shares), not text.
- **Takedowns.** The weekly `last-modified` sweep checks `isGone` / `isExpired`. Removed articles are deleted from raw and clean and excluded from future training snapshots.
- **No redistribution.** Raw and clean data never go into the Git repository or a public bucket; the DVC remote is a private MinIO bucket.

### 6.6 Monitoring and alarms

First draft; Lab 4 makes it real.

**What is logged.**
- Every online and batch prediction to `predictions`: `article_id`, `model_version`, `section`, `confidence`, `top3`, `fallback_used`, `latency_ms`, `request_ts`.
- Request metrics to Prometheus.
- Pipeline task outcomes and row counts from Airflow.

**Metrics and thresholds.**

| Signal | Metric | Threshold | Window | Alert to |
|---|---|---|---|---|
| Freshness | Age of the newest article in clean / online store | > 30 h | checked hourly | On-call ML engineer (e-mail) |
| Volume | Articles ingested for day D vs median of the previous 28 days | < 50% or > 200% | daily | On-call |
| **Stale partition** | Ingested `max(webPublicationDate)` ≠ the run's logical date `ds` (the job read an old partition while "succeeding") | any mismatch | daily | On-call |
| Quality gate | `validate_batch` failed | any failure | per run | On-call |
| Unmapped sections | Share of `other` / unmapped `sectionId` | > 5% | daily | On-call; model owner updates the section map |
| Prediction drift | Jensen–Shannon distance of the predicted-class distribution vs the reference (training) window | > 0.1 | 7-day rolling | On-call |
| Input drift | Evidently text-drift test on TF-IDF features vs reference | drift detected | 7-day rolling | On-call |
| Confidence | Share of predictions with confidence < 0.5 | > 25% | daily | On-call |
| Quality (after labels) | Macro-F1 of the last 7 labelled days | < 0.75 or drop > 0.05 from test score | daily | On-call → triggers `train_classifier` |
| Fallback use | Share of `fallback_used = true` | > 1% | 1 h | On-call |
| Service | p95 latency; 5xx rate | > 300 ms; > 1% | 5 min | On-call |
| API limits | Guardian HTTP 403/429 responses | any | per run | On-call |

**Who receives alerts.** Grafana alerting sends an e-mail to the on-call ML engineer (the repository owner). Retraining is triggered automatically by the quality rule; promotion still needs approval (5.5).

### 6.7 Cost

To be completed: monthly cloud estimate for the managed column of 6.2, using the AWS, Google Cloud and Azure pricing calculators, with the volume assumptions of 6.3.

### 6.8 Integration points

| Party | Direction | Owner | Contract |
|---|---|---|---|
| Guardian Content API | Upstream (data and labels) | Guardian News & Media | REST/JSON over HTTPS; fields and tag types as in the public content model; developer key, non-commercial terms. Rate limit: Assumption 500 calls/day and 1 call/s until measured from response headers. Schema changes are not announced to us, so `validate_batch` checks the schema on every batch (6.9). |
| Editorial desk / CMS (`cms-client`) | Downstream (online) | Project (emulated) | `POST /classify`, JSON in `{headline, standfirst, body_text, contributor_ids, production_office, published_at}`, JSON out `{section, confidence, top3, model_version, fallback_used}`. p95 ≤ 300 ms. Unknown fields ignored. On errors the client keeps the editor's manual choice. The API is versioned by path (`/v1/`). |
| Newsroom analytics | Downstream (batch) | Project | Table `predictions` in PostgreSQL, one row per article per model version, complete for day D by 06:00 UTC on D+1. Columns are additive only; renames need a new table version. |
| On-call ML engineer | Downstream (alerts) | Repository owner | E-mail from Grafana with the rule name, current value, threshold and a link to the dashboard or Evidently report. |

### 6.9 Risks and uncertainties

| Risk | Likelihood / impact | Mitigation |
|---|---|---|
| Guardian key not issued, revoked, or limits stricter than assumed | Medium / high | Raw snapshots in DVC so the project runs without live calls; backfill paced under 400 calls/day; documented fallback dataset (BBC News All-Time) |
| API schema or field change | Medium / high | Schema check in `validate_batch`; pipeline stops instead of writing bad data; pinned request fields |
| Section taxonomy change (new or renamed `sectionId`) | High over months / medium | Versioned section map; unmapped share monitored with an alert at 5% |
| Label leakage through URL, ids, keyword or series tags | High if unchecked / high | Leaking fields dropped in `clean_transform`; a unit test asserts that no feature column is derived from them |
| Concept drift (new events, news cycles) | High / medium | Daily drift and quality monitoring, weekly retraining, champion/challenger gate |
| Class imbalance (sport and world dominate) | High / medium | Macro-F1 as the optimizing metric, class weights, per-class recall floor |
| Guardian terms on storing content | Low–medium / high | Non-commercial student use (confirmed by Guardian staff); private storage only; retention limit; takedown sweep |
| Local resources (8 GB RAM) too small for the full stack | Medium / medium | Services started per lab; Minikube capped at 4 GB; training on a sample if needed |
| Guardian API outage during the demo | Low / medium | Serving does not depend on the Guardian API; replayed production months give a deterministic demo |
| Contributor features are sparse for new or rare authors | High / low | Global prior as default; features added only if they improve macro-F1 on validation |

---

## 7 Appendix

### 7.1 Alternatives

| Alternative | Pros | Cons | Decision |
|---|---|---|---|
| **BBC News All-Time** (Hugging Face, monthly Parquet 2017–2025) instead of the Guardian API | No key, one file per month, full text | Frozen since 2025-06-28; ~30% duplicate rows; `authors` empty; 64–129 mostly geographic sections, 7–19% missing; no licence stated | Rejected as primary; kept as fallback (6.9) |
| **HuffPost News Category** (209k articles, 2012–2022, CC BY 4.0) | Open licence, measured drift, single file | Headline + ~20-word description only; volume drops ~15× after May 2018; no new data | Rejected: too little text for Lab 3, no live collection |
| **Multi-label keyword-tag classification** | Richer output, closer to Guardian tagging | Tag ids leak the section; thousands of long-tail labels; hard to evaluate | Rejected (5.1) |
| **Fine-tuned transformer** (e.g., DistilBERT) instead of TF-IDF + logistic regression | Usually higher accuracy on text | GPU or slow CPU training; larger image; harder to reproduce; model quality is not graded | Deferred: candidate for a later challenger if time allows |
| **Streaming ingestion** (Kafka + Spark) instead of daily batches | Lower latency to ingest | ~250 articles/day does not need streaming; much more infrastructure | Rejected: daily batch meets the freshness requirement |
| **No feature store** (all features computed from the request) | Simpler | No point-in-time history features; skew risk if history features are later added ad hoc | Rejected: Feast gives contributor and office features with one definition for training and serving |

### 7.2 Experiment results

Placeholder. Filled in Lab 2: baseline vs candidate on the test window, per-class results, rolling-origin decay, link to MLflow runs.

### 7.3 Performance results

Placeholder. Filled in Lab 4: measured latency and throughput of `classifier-api` on Minikube, batch durations, monitoring screenshots.

### 7.4 Milestones

| Lab | What it adds to this system |
|---|---|
| Lab 2 | Docker Compose stack (MinIO, PostgreSQL, Airflow, MLflow, Feast); `guardian_ingest_daily` with `validate_batch` and DVC snapshots; clean layer and section map; `contributor_stats` / `office_stats` feature views; keyword baseline and TF-IDF model trained on the time-based split, tracked and registered in MLflow with data version and commit; tests in CI. |
| Lab 3 | An LLM component over the Guardian full-text corpus: retrieval of similar past articles (pgvector or Qdrant) to explain a suggested section and answer editors' questions about recent coverage, with a retrieval and answer evaluation set and versioned prompts. |
| Lab 4 | `classifier-api` and monitoring on Minikube with health and readiness probes; `score_batch_daily` and `monitor_daily`; Evidently reports and Grafana dashboards; an injected drift (replay of a month with a shifted section mix) crossing a threshold and reaching the on-call e-mail; one command to bring the system up. |
| Lab 5 | An agent that uses the system: pulls the day's articles through the Guardian API, calls `/classify`, explains low-confidence cases with the Lab 3 retrieval, and drafts a daily topic-volume brief, with traces and a 10-task evaluation. |
