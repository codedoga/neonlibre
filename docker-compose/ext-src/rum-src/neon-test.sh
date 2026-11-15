#!/usr/bin/env bash
# rum_validate's PGPRO-1175 query relies on the unsafe cross-rowtype deforming that
# PostgreSQL 18.7 (cfdd09589b) now guards against, so it returns garbage there. Upstream
# disabled it too: https://github.com/postgrespro/rum/issues/189. Re-enable once rum fixes it.
set -ex
cd "$(dirname "${0}")"
# One line: a newline in the value would end the make command.
REGRESS="security rum rum_hash ruminv timestamp orderby orderby_hash altorder altorder_hash limits int2 int4 int8 float4 float8 money oid time timetz date interval macaddr inet cidr text varchar char bytea bit varbit numeric rum_weight expr array"
USE_PGXS=1 make installcheck REGRESS="${REGRESS}"
