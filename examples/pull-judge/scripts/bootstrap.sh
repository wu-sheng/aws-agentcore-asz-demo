#!/usr/bin/env bash
# Prepare only this example's toolchain; do not change the previous blog demo.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ASZ_COMMIT=4ff3d426780d28ef06bced7050d60426e9cebbff
cd "$ROOT"
for tool in git go uv openssl; do
  command -v "$tool" >/dev/null || { echo "Missing tool: $tool" >&2; exit 1; }
done
mkdir -p .work/bin
if [ ! -e .work/asz-src/.git ]; then
  git init -q .work/asz-src
  git -C .work/asz-src remote add origin https://github.com/apache/skywalking-ai-sessionizer.git
  git -C .work/asz-src fetch -q --depth=1 origin "$ASZ_COMMIT"
  git -C .work/asz-src checkout -q --detach FETCH_HEAD
fi
test "$(git -C .work/asz-src rev-parse HEAD)" = "$ASZ_COMMIT" || {
  echo "Existing .work/asz-src is not the pinned commit; use a separate workspace." >&2
  exit 1
}
(
  cd .work/asz-src
  go build -ldflags "-X main.version=$ASZ_COMMIT" -o ../bin/asz ./cmd/asz
  go build -o ../bin/asz-changes ./plugins/claude-code
)
if [ ! -d .venv ]; then uv venv .venv --python 3.12; fi
uv pip install --python .venv/bin/python -r agent/requirements.txt .work/asz-src/plugins/langchain
.venv/bin/asz-langchain enable
.venv/bin/python -m unittest discover -s agent -p 'test_*.py'
.venv/bin/python scripts/local.py
