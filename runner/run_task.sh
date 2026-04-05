#!/bin/bash
set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# run_task.sh — Ollama Task Runner
#
# Executes tasks via a local Ollama instance with exclusivity locking.
# Locking prevents concurrent Ollama calls that would degrade generation quality.
#
# Configuration (environment variables):
#   WORKER_ROOT     Root directory for the worker (default: $HOME/worker)
#   PROJECTS_DIR    Directory containing projects (default: $WORKER_ROOT/projects)
#   DEFAULT_PROJECT Default project name used for context (default: "")
#   OLLAMA_MODEL    Model to use for code generation (default: qwen2.5-coder:32b)
#   OLLAMA_URL      Ollama API endpoint (default: http://localhost:11434/api/generate)
#   OLLAMA_TIMEOUT  Max seconds to wait for Ollama response (default: 300)
# ─────────────────────────────────────────────────────────────────────────────

WORKER_ROOT="${WORKER_ROOT:-$HOME/worker}"
PROJECTS_DIR="${PROJECTS_DIR:-$WORKER_ROOT/projects}"
DEFAULT_PROJECT="${DEFAULT_PROJECT:-}"
OLLAMA_MODEL="${OLLAMA_MODEL:-qwen2.5-coder:32b}"
OLLAMA_URL="${OLLAMA_URL:-http://localhost:11434/api/generate}"
OLLAMA_TIMEOUT="${OLLAMA_TIMEOUT:-300}"

QUEUE_DIR="$WORKER_ROOT/queue"
LOCK_DIR="$QUEUE_DIR/ollama.lock.d"

TASK="${1:-}"
shift || true

# ── Locking ───────────────────────────────────────────────────────────────────
# Only acquire lock for tasks that call Ollama
NEEDS_LOCK=false
case "$TASK" in
  codegen|write) NEEDS_LOCK=true ;;
esac

acquire_lock() {
  mkdir "$LOCK_DIR" 2>/dev/null || {
    echo "ERROR: Ollama is locked by another task ($(cat "$LOCK_DIR/pid" 2>/dev/null || echo 'unknown PID')). Try again shortly or run queue_status.sh clean."
    exit 1
  }
  echo $$ > "$LOCK_DIR/pid"
}

release_lock() {
  rm -rf "$LOCK_DIR"
}

if [ "$NEEDS_LOCK" = true ]; then
  mkdir -p "$QUEUE_DIR"
  acquire_lock
  trap release_lock EXIT
fi

# ── Job status header ─────────────────────────────────────────────────────────
print_status() {
  local active
  local api_base="${OLLAMA_URL%/api/generate}"
  active=$(curl -s --max-time 3 "$api_base/api/ps" 2>/dev/null | python3 -c \
    "import sys,json; m=json.load(sys.stdin).get('models',[]); print(m[0]['name']+' (busy)' if m else 'idle')" 2>/dev/null || echo "unknown")
  local lock_state="clear"
  if [ -d "$LOCK_DIR" ]; then
    lock_state="locked (PID $(cat "$LOCK_DIR/pid" 2>/dev/null || echo '?'))"
  fi
  echo "┌─ Job: $TASK | Model: ${OLLAMA_MODEL} | Ollama: $active | Lock: $lock_state"
  echo "└─ Started: $(date '+%H:%M:%S') | Timeout: ${OLLAMA_TIMEOUT}s"
}

echo "=== RUNNER START ==="
print_status

# ── Ollama generation ─────────────────────────────────────────────────────────
ollama_generate() {
  local instruction="$1"
  local code_only="${2:-false}"
  local prompt="$instruction"

  # Prepend project context if available
  if [ -n "$DEFAULT_PROJECT" ]; then
    local context_file="$PROJECTS_DIR/$DEFAULT_PROJECT/AGENT.md"
    if [ -f "$context_file" ]; then
      local context
      context=$(cat "$context_file")
      prompt="Project context:
$context

Task: $instruction"
    fi
  fi

  if [ "$code_only" = "true" ]; then
    prompt="$prompt

Return ONLY the complete source code. No explanation, no markdown fences, no prose. Start directly with the code."
  fi

  local json_prompt
  json_prompt=$(printf '%s' "$prompt" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')

  curl -s --max-time "$OLLAMA_TIMEOUT" "$OLLAMA_URL" -d "{
    \"model\": \"$OLLAMA_MODEL\",
    \"prompt\": $json_prompt,
    \"stream\": false
  }" | python3 -c 'import sys,json; print(json.load(sys.stdin)["response"])'
}

# ── Strip markdown fences — return pure code ──────────────────────────────────
strip_to_code() {
  python3 - "$1" << 'PYEOF'
import sys, re

text = open(sys.argv[1]).read()

blocks = re.findall(r'```(?:\w+)?\n(.*?)```', text, re.DOTALL)
if blocks:
    print(blocks[0].rstrip())
else:
    lines = text.splitlines()
    code_lines = [l for l in lines if not re.match(r'^(###|##|#|\*\*|--)', l)]
    print('\n'.join(code_lines).strip())
PYEOF
}

# ── Commands ──────────────────────────────────────────────────────────────────
case "$TASK" in
  help)
    cat << 'HELP'
Ollama Task Runner — powered by a local Ollama model.

Commands:

  ping
    Check runner is alive.

  codegen <instruction>
    Generate code from an instruction using the configured Ollama model.
    Usage: run_task.sh codegen "write a Python function to parse JSON"

  write <relative/path/file.ext> <instruction>
    Generate code and write it to a file inside the project directory.
    Prose and markdown fences are stripped — file gets pure code.
    Usage: run_task.sh write src/utils.py "write a retry decorator"

  test [suite]
    Run tests for the configured project.
    Usage: run_task.sh test
    Usage: run_task.sh test <suite_name>

  exec <shell command>
    Run any shell command on this machine.
    Usage: run_task.sh exec "ls ~/worker/projects"

  list-projects
    List available projects in PROJECTS_DIR.

Environment variables:
  WORKER_ROOT, PROJECTS_DIR, DEFAULT_PROJECT, OLLAMA_MODEL, OLLAMA_URL

HELP
    ;;

  ping)
    echo "RUNNER_OK"
    ;;

  list-projects)
    ls "$PROJECTS_DIR"
    ;;

  test)
    SUITE="${1:-all}"
    if [ -z "$DEFAULT_PROJECT" ]; then
      echo "ERROR: DEFAULT_PROJECT is not set. Export it before running tests."
      exit 1
    fi
    PROJECT_DIR="$PROJECTS_DIR/$DEFAULT_PROJECT"
    cd "$PROJECT_DIR"
    case "$SUITE" in
      all)
        if [ -f "backend/venv/bin/python" ]; then
          ./backend/venv/bin/python -m pytest backend/tests/ --verbose
        else
          echo "ERROR: Python venv not found at backend/venv"
          exit 1
        fi
        ;;
      *)
        if [ -f "backend/venv/bin/python" ]; then
          ./backend/venv/bin/python -m pytest "backend/tests/test_${SUITE}.py" --verbose
        else
          echo "ERROR: Python venv not found at backend/venv"
          exit 1
        fi
        ;;
    esac
    ;;

  codegen)
    INSTRUCTION="${*}"
    if [ -z "$INSTRUCTION" ]; then
      echo "ERROR: no instruction provided"
      echo "Usage: run_task.sh codegen \"write a function to...\""
      exit 1
    fi
    ollama_generate "$INSTRUCTION" false
    ;;

  write)
    REL_FILE="${1:-}"
    shift || true
    INSTRUCTION="${*}"

    if [ -z "$REL_FILE" ] || [ -z "$INSTRUCTION" ]; then
      echo "ERROR: missing file path or instruction"
      echo "Usage: run_task.sh write <relative/path/file.ext> <instruction>"
      exit 1
    fi

    if [ -z "$DEFAULT_PROJECT" ]; then
      echo "ERROR: DEFAULT_PROJECT is not set."
      exit 1
    fi

    TARGET_FILE="$PROJECTS_DIR/$DEFAULT_PROJECT/$REL_FILE"
    TMP_FILE=$(mktemp /tmp/ollama_output_XXXXXX)

    mkdir -p "$(dirname "$TARGET_FILE")"
    ollama_generate "$INSTRUCTION" true > "$TMP_FILE"
    strip_to_code "$TMP_FILE" > "$TARGET_FILE"
    rm -f "$TMP_FILE"

    echo "WROTE: $TARGET_FILE"
    ;;

  exec)
    CMD="${*}"
    if [ -z "$CMD" ]; then
      echo "ERROR: no command provided"
      exit 1
    fi
    eval "$CMD"
    ;;

  "")
    echo "ERROR: no task specified. Run: run_task.sh help"
    exit 1
    ;;

  *)
    echo "ERROR: Unknown task: $TASK. Run: run_task.sh help"
    exit 1
    ;;
esac

echo "=== RUNNER END ==="
