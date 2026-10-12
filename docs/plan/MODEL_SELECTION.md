# Model Selection for One and Two L40S

| | |
| :-- | :-- |
| **Date** | 2026-10-12 |
| **Decision** | DEC-009, proposed: **Qwen3.8-27B FP8** in both profiles. `l40s-1`: 64k context, 16 sequences. `l40s-2`: tensor parallel, 128k context, 32 sequences |
| **Status** | Desk selection. Nothing here has run on an L40S. The profiles are `PROFILE_STATUS=candidate` until PLAN P5 records AC-3.1 and the golden-set result ([ADR-013](../adr/ADR-013-measure-before-adopting.md)) |
| **Sources** | Hugging Face API (sizes, revisions, `config.json`, licences), model cards (vendor-reported scores), vLLM `v0.31.0` source (architectures, parsers, flags) |

## 1. Requirements the model must meet

| # | Requirement | From |
| :-- | :-- | :-- |
| M1 | Fits one L40S with real KV headroom (budget 40.5 GiB = 0.90 × 45.0 GiB) and, separately, two L40S | ADR-012 |
| M2 | ≥ 64k context in every production profile; OpenAI tool calling; streaming | ADR-014 (agents) |
| M3 | Strong at science, reasoning, code (R, Python), instruction following; good in Italian and English | PRD (BIOME researchers) |
| M4 | Licence that allows institutional use without fees or user caps (Apache-2.0 or MIT preferred) | PRD |
| M5 | Architecture and quantisation supported by the pinned vLLM (v0.31.0) on Ada (sm_89, native FP8) | ADR-003 |
| M6 | Weights pinned by revision, downloadable without a gated agreement | F-01 |

## 2. Candidates (measured inputs)

Sizes are the sum of `.safetensors` files. For gpt-oss the repository also holds the original checkpoint, so the loaded size is about half of the listed one.

| Model | Revision | Size | Active params | Licence | Notes |
| :-- | :-- | :-- | :-- | :-- | :-- |
| **Qwen/Qwen3.8-27B-FP8** | `017b9c7a` | 30.9 GB | 27B dense | Apache-2.0 | 2026-08; hybrid attention (16 of 64 layers full, 48 linear), 262k native, thinking on/off per request, vision encoder |
| Qwen/Qwen3.6-35B-A3B-FP8 | `95a723d0` | 37.5 GB | 3B (MoE) | Apache-2.0 | hybrid, 262k |
| Qwen/Qwen3.6-27B-FP8 | `e89b16eb` | 30.9 GB | 27B dense | Apache-2.0 | predecessor of 3.8-27B, same architecture |
| google/gemma-4-31B-it (RedHatAI FP8 `d4ab4f57`) | | 33.3 GB | 31B dense | Apache-2.0 | sliding window 1024 + 10 global layers |
| google/gemma-4-26B-A4B-it (RedHatAI FP8 `ed35d7ab`) | | 28.6 GB | 4B (MoE) | Apache-2.0 | |
| openai/gpt-oss-120b | `b5c939de` | ~65 GB loaded | 5.1B (MoE) | Apache-2.0 | MXFP4, 2025-08 |
| openai/gpt-oss-20b | `6cee5e81` | ~14 GB loaded | 3.6B (MoE) | Apache-2.0 | |
| Qwen/Qwen3-Coder-30B-A3B-Instruct-FP8 | `dcaee4d4` | 31.2 GB | 3B (MoE) | Apache-2.0 | coding specialist, 2025-07 |
| RedHatAI/Qwen2.5-72B-Instruct-FP8-dynamic | `4d9910ef` | 75.2 GB | 72B dense | Qwen licence | current baseline, 2024 |
| Qwen/Qwen3-Next-80B-A3B-Instruct-FP8 | `c5f5f263` | 82.1 GB | 3B | Apache-2.0 | does not fit 2 × 40.5 GiB with any KV |
| Qwen/Qwen3.8-Flash-Next-FP8 | `236dfdf2` | 185.5 GB | — | other | does not fit |
| mistralai/Mistral-Small-4-119B-2603 | | 241.9 GB (FP8 release) | — | Apache-2.0 | does not fit |

## 3. Fit (computed)

Budget per GPU: 40.5 GiB. Activations and CUDA graphs: 2-3 GiB per GPU (estimate, PRD §2). Per-token cache only for full-attention layers. Hybrid models also hold a fixed linear-attention state per running sequence.

| Model | 1 × L40S: cache left | 1 × L40S: verdict | 2 × L40S (TP=2): cache left | 2 × L40S: verdict |
| :-- | :-- | :-- | :-- | :-- |
| **Qwen3.8-27B FP8** | ~9-10 GiB; 64 KiB/token + ~72 MiB/sequence → ~130k tokens with 16 sequences | **fits**, 64k context | ~47 GiB → ~700k tokens | **fits**, 128k context, 32 sequences |
| Qwen3.6-35B-A3B FP8 | ~3-4 GiB minus ~30 MiB/sequence | too tight | ~40 GiB | fits (speed challenger) |
| Gemma 4 31B FP8 | ~5 GiB; sliding layers cost ~0.8 GiB per sequence | too few sequences | ~40 GiB | fits |
| Gemma 4 26B-A4B FP8 | ~9 GiB | fits | ~45 GiB | fits |
| gpt-oss-120b | does not fit | — | ~16 GiB, 36 KiB/token | fits |
| gpt-oss-20b | ~24 GiB | fits easily | — | — |
| Qwen2.5-72B FP8 (baseline) | does not fit | — | 6-8 GiB → 16k context | fits, barely |

## 4. Quality (vendor-reported, not verified here)

Vendors pick the benchmarks they publish, so only rows reported by the same vendor for several models are compared:

| Benchmark | Qwen3.8-27B | Qwen3.6-27B | Qwen3.6-35B-A3B | Gemma 4 31B | Gemma 4 26B-A4B |
| :-- | :-- | :-- | :-- | :-- | :-- |
| GPQA Diamond (science) | **89.2** | 87.8 | 86.0 | 84.3 | 82.3 |
| HLE, no tools | **30.8** | 24.0 | 21.4 | 19.5 | 8.7 |
| LiveCodeBench v6 | **90.3** | 83.9 | 80.4 | 80.0 | 77.1 |
| Terminal-Bench (agentic) | **73.0** (v2.1) | 63.4 (v2.1) | 51.5 (v2.0) | 42.9 (v2.0) | 34.2 (v2.0) |
| SWE-bench Verified | — | 77.2 | 73.4 | 52.0 | 17.4 |
| MMMLU (multilingual) | — | — | — | 88.4 | 86.3 |

Sources: Qwen3.8-27B card (vs Qwen3.6-27B); Qwen3.6-35B-A3B card (vs Gemma 4); Qwen3.6-27B card; Gemma 4 cards. gpt-oss is not in the table because its Hugging Face card publishes no comparable rows; it stays a P5 challenger only for `l40s-1` speed (20b).

## 5. Recommendation and why

**Both profiles: Qwen3.8-27B FP8.**

1. **It fits one card with real headroom.** Among the models that leave enough cache on a single L40S, it has the highest reported scores on every comparable row (M1, M3).
2. **Same model on one and two GPUs.** One quality evaluation covers both profiles, researchers get the same answers whichever way DEC-008 goes, and moving the second card changes capacity only.
3. **Agents:** tool calling (`qwen3_coder` parser) and 262k native context. Thinking is on by default and can be turned off per request (`chat_template_kwargs: {"enable_thinking": false}`), which matters for latency (M2).
4. **Apache-2.0**, not gated (M4, M6). The architecture (`Qwen3_5ForConditionalGeneration`) and both parsers are in vLLM v0.31.0 (M5).
5. **Vision** comes with it: images are enabled in `l40s-2` (figures, plots, scanned tables) and off in `l40s-1` to save memory.

Costs and risks, stated:
- **Dense 27B decodes slower than a 3B-active MoE.** On one L40S (864 GB/s), single-stream decode is bounded at about 30 tokens/s (computed from bandwidth ÷ weights). The MoE challengers would be several times faster per stream. P5 measures whether that matters at the real concurrency.
- **Thinking costs tokens and time.** The default `preserve_thinking: false` keeps old reasoning out of the context. Open WebUI users can switch thinking off per chat.
- **Parsers are taken from the Qwen3.6 card** (same architecture). The Qwen3.8 card does not list them. The lab profile (Qwen3.5-0.8B, same architecture) checks the plumbing; P5 checks the 27B.
- **FP8 KV cache is off** (`auto` = BF16). The hybrid layout already leaves enough cache, which removes the DEC-007 accuracy question for these profiles.

## 6. What P5 must measure before `PROFILE_STATUS=validated`

| Profile | Baseline | Challengers | Gate (pre-registered, ADR-013) |
| :-- | :-- | :-- | :-- |
| `l40s-1` | Qwen3.8-27B FP8, 64k | Gemma 4 26B-A4B FP8 (speed); gpt-oss-20b (speed, small) | golden set ≥ baseline −2 pp; p95 TTFT at concurrency 8 ≤ 3 s; ≥ 64k with tool calls |
| `l40s-2` | Qwen3.8-27B FP8, TP=2, 128k | same model, 2 replicas (`--data-parallel-size 2`, no NCCL); Qwen3.6-35B-A3B FP8 TP=2 | same, plus throughput at concurrency 32 as the primary metric |

The current 72B baseline is run once in `l40s-2` as a reference row, then retired if the gate passes.
