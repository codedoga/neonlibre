#!/usr/bin/env bash
# pgrag's model extensions on a Neon compute. They need shared_preload_libraries (each
# runs a background worker) and download their ONNX model from Hugging Face on first
# use, so this checks that the download works and the models give sensible answers.
#
#   PRELOAD_EXTRA=rag_bge_small_en_v15,rag_jina_reranker_v1_tiny_en PG_VERSION=18 ci/rag-model-test.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
[[ ",${PRELOAD_EXTRA:-}," == *,rag_bge_small_en_v15,*rag_jina_reranker_v1_tiny_en,* ]] ||
    die "run with PRELOAD_EXTRA=rag_bge_small_en_v15,rag_jina_reranker_v1_tiny_en"

trap '[[ "${KEEP_UP:-0}" == 1 ]] || dc down -v --remove-orphans >/dev/null 2>&1' EXIT
dc down -v --remove-orphans >/dev/null 2>&1 || true
dc up -d --build compute1
wait_ready

sql 'create extension rag_bge_small_en_v15 cascade'
sql 'create extension rag_jina_reranker_v1_tiny_en cascade'
dims="$(sql "select vector_dims(rag_bge_small_en_v15.embedding_for_passage('The quick brown fox jumps over the lazy dog'))")"
[[ "${dims}" == 384 ]] || die "bge embedding has ${dims} dimensions, expected 384"
# A relevant passage must rank closer than an unrelated one.
closer="$(sql "select rag_jina_reranker_v1_tiny_en.rerank_distance('What did the quick brown fox jump over?', 'The quick brown fox jumps over the lazy dog')
             < rag_jina_reranker_v1_tiny_en.rerank_distance('What did the quick brown fox jump over?', 'Never Eat Shredded Wheat')")"
[[ "${closer}" == t ]] || die "reranker does not rank the relevant passage first"
echo "RAG MODELS OK"
