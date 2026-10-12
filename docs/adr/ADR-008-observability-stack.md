# ADR-008: Prometheus & NVIDIA DCGM Metrics Integration

**Status:** Accepted — **not implemented** (no Prometheus/DCGM in the stack yet).

## Context
System administrators require real-time visibility into GPU temperatures, VRAM consumption, TTFT (Time To First Token), and error rates.

## Decision
Expose vLLM native metrics and NVIDIA DCGM exporter endpoints to a centralized Prometheus monitoring service.

## Rationale
Enables proactive alerting before GPU memory exhaustion or thermal throttling degrades user experience.
