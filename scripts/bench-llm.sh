#!/bin/bash
# LLM engine benchmark: Ollama vs MLX on the same synthetic prompts (local only).
#
# Generates synthetic therapy-session transcripts (no PHI, fixed seed) at a few
# sizes, sends each to Ollama and, if installed, MLX, and prints prompt-reading
# speed (prefill), writing speed (decode) and wall time. Note writing is
# prefill-bound: long transcript in, short note out, so prefill decides.
#
# Usage:
#   scripts/bench-llm.sh [--sizes 8,32,64] [--runs 4] [--ollama-model llama3.1:8b]
#       [--mlx-model mlx-community/Meta-Llama-3.1-8B-Instruct-4bit] [--no-mlx]
#     --sizes   prompt sizes in thousands of tokens (approximate; actual counts
#               are printed).
#     --runs    runs per case; the first is discarded (model load), the median
#               of the rest is reported.
#
# MLX is optional: install it in a throwaway venv (`pip install mlx-lm`) so
# `mlx_lm.generate` is on PATH; it downloads the model from Hugging Face on
# first use. Compare like with like: Ollama's llama3.1:8b is q4_K_M (~4.8
# bits/weight), the MLX 4bit build ~4.5. Plug in and close other apps first.
#
# Also measures Ollama's prefix cache: the same prompt with a different last
# line, as a chat follow-up would send.

set -euo pipefail
cd "$(dirname "$0")/.."

SIZES="8,32,64"; RUNS=4; OLLAMA_MODEL="llama3.1:8b"
MLX_MODEL="mlx-community/Meta-Llama-3.1-8B-Instruct-4bit"; USE_MLX=1
OLLAMA="${OLLAMA_HOST:-http://127.0.0.1:11434}"
while [ $# -gt 0 ]; do
    case "$1" in
        --sizes) SIZES="$2"; shift 2 ;;
        --runs) RUNS="$2"; shift 2 ;;
        --ollama-model) OLLAMA_MODEL="$2"; shift 2 ;;
        --mlx-model) MLX_MODEL="$2"; shift 2 ;;
        --no-mlx) USE_MLX=0; shift ;;
        -h|--help) sed -n '2,/^$/p' "$0"; exit 0 ;;
        *) sed -n '2,/^$/p' "$0"; exit 2 ;;
    esac
done
[ "$RUNS" -ge 2 ] || { echo "--runs must be at least 2 (the first is discarded)" >&2; exit 2; }
curl -sf "$OLLAMA/api/tags" >/dev/null || { echo "Ollama isn't reachable at $OLLAMA" >&2; exit 2; }
if [ "$USE_MLX" = 1 ] && ! command -v mlx_lm.generate >/dev/null; then
    echo "mlx_lm.generate not on PATH: Ollama only (pip install mlx-lm to compare)." >&2
    USE_MLX=0
fi

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# A synthetic session of about $1 thousand tokens (this word list runs ~5
# characters a token), same seed every time so runs and machines compare.
make_prompt() {
    awk -v chars=$(($1 * 5000)) 'BEGIN {
        srand(1)
        n = split("feel felt work sleep mother father partner anxious week tired " \
            "argument weekend family job boss panic breathing exercise journal " \
            "noticed thoughts better worse avoid called friend sister brother " \
            "morning night appointment medication walk eating stress deadline " \
            "angry sad calm guilty proud relief worried school kids home house " \
            "moved talked cried laughed waiting trying again maybe really pretty", w, " ")
        print "Write a concise progress note for this therapy session.\n"
        total = 0; t = 0
        while (total < chars) {
            line = sprintf("[%02d:%02d] %s:", int(t / 60), t % 60, (NR++ % 2 ? "Client" : "Therapist"))
            len = 6 + int(rand() * 18)
            for (i = 0; i < len; i++) line = line " " w[1 + int(rand() * n)]
            print line "."
            total += length(line) + 2; t += 4 + int(rand() * 12)
        }
    }'
}

# The app's own window sizing (OllamaClient.contextSize): a power of two with
# room for the reply, so the cache test below reuses the same window.
num_ctx() { local need=$(($1 / 3 + 2048)) size=8192; while [ $size -lt $need ] && [ $size -lt 131072 ]; do size=$((size * 2)); done; echo $size; }

# A copy of the prompt with a different first line, so no run reuses an
# earlier run's cached prompt (Ollama keeps it; that would skip prefill).
variant() { { echo "Session reference: run-$2-$RANDOM"; cat "$1"; } > "$1.$2"; echo "$1.$2"; }

# Prints "prompt_tokens prefill_s prefill_tps decode_tps wall_s" for one Ollama request.
ollama_run() {
    jq -n --rawfile p "$1" --arg m "$OLLAMA_MODEL" --argjson ctx "$2" \
        '{model:$m, prompt:$p, stream:false, options:{num_ctx:$ctx, num_predict:256, temperature:0, seed:1}}' |
    curl -sf "$OLLAMA/api/generate" -d @- |
    jq -r '(.prompt_eval_duration / 1e9) as $pd | (.eval_duration / 1e9) as $ed |
        [.prompt_eval_count, $pd, (if $pd > 0 then .prompt_eval_count / $pd else 0 end),
         (if $ed > 0 then .eval_count / $ed else 0 end), (.total_duration - .load_duration) / 1e9] | @tsv'
}

# Same fields from mlx_lm.generate's summary lines, plus peak memory in GB.
# Each call is a new process that loads the model, so wall time is derived
# from its own rates (prefill + 256 tokens), excluding the load.
mlx_run() {
    local stderr_file
    stderr_file=$(mktemp)
    trap "rm -f '$stderr_file'" RETURN

    mlx_lm.generate --model "$MLX_MODEL" --prompt "$(cat "$1")" --max-tokens 256 --temp 0 --seed 1 2>"$stderr_file" |
    awk -v stderrfile="$stderr_file" '/^Prompt:/ { pt = $2; ptps = $4 }
        /^Generation:/ { gt = $2; gtps = $4 }
        /^Peak memory:/ { mem = $3 }
        END {
            if (!pt || !ptps || !gt || !gtps || !mem) {
                print "mlx_lm.generate: no summary line (context too large?); last stderr lines:" > "/dev/stderr"
                linecount = 0; while ((getline line < stderrfile) > 0) saved_lines[linecount++ % 5] = line
                start = (linecount < 5) ? 0 : linecount - 5
                for (i = start; i < linecount; i++) print "  " saved_lines[i % 5] > "/dev/stderr"
            } else {
                printf "%s\t%.2f\t%s\t%s\t%.2f\t%s\n", pt, pt / ptps, ptps, gtps, pt / ptps + gt / gtps, mem
            }
        }'
}

# Median of each column over runs 2..N (run 1 is load/warm-up). A failed MLX
# run prints no row, so the median covers only the runs that finished.
median_rows() {
    tail -n +2 | awk -F'\t' '{ for (i = 1; i <= NF; i++) v[i, NR] = $i; nf = NF; n = NR }
        END { for (i = 1; i <= nf; i++) {
            for (r = 1; r <= n; r++) a[r] = v[i, r]
            for (x = 1; x <= n; x++) for (y = x + 1; y <= n; y++) if (a[y] + 0 < a[x] + 0) { t = a[x]; a[x] = a[y]; a[y] = t }
            printf "%s%s", (n % 2 ? a[(n + 1) / 2] : (a[n / 2] + a[n / 2 + 1]) / 2), (i < nf ? "\t" : "\n") } }'
}

ROW="%-7s %-5s %7s %10s %12s %11s %8s %7s\n"
printf "$ROW" engine size tokens prefill_s prefill_t/s decode_t/s wall_s mem_GB
for k in ${SIZES//,/ }; do
    prompt="$WORK/prompt-$k.txt"; make_prompt "$k" > "$prompt"
    ctx=$(num_ctx "$(wc -c < "$prompt")")

    for i in $(seq "$RUNS"); do ollama_run "$(variant "$prompt" "$i")" "$ctx"; done > "$WORK/o-$k.tsv"
    mem=$(curl -sf "$OLLAMA/api/ps" | jq -r --arg m "$OLLAMA_MODEL" '.models[] | select(.name == $m) | .size / 1e9' | head -1)
    median_rows < "$WORK/o-$k.tsv" | awk -F'\t' -v row="$ROW" -v k="${k}K" -v mem="$mem" \
        '{ printf row, "ollama", k, $1, sprintf("%.1f", $2), sprintf("%.0f", $3), sprintf("%.1f", $4), sprintf("%.1f", $5), sprintf("%.1f", mem) }'

    # Prefix cache: the last run's prompt with only its last line changed, as
    # a chat follow-up sends. A small prefill_s means the cache was reused.
    sed '$ s/.*/[99:59] Therapist: and one last thing before we finish./' "$prompt.$RUNS" > "$WORK/follow-$k.txt"
    ollama_run "$WORK/follow-$k.txt" "$ctx" | awk -F'\t' -v row="$ROW" -v k="${k}K" \
        '{ printf row, "ollama*", k, $1, sprintf("%.1f", $2), "-", sprintf("%.1f", $4), sprintf("%.1f", $5), "" }'

    if [ "$USE_MLX" = 1 ]; then
        for i in $(seq "$RUNS"); do mlx_run "$(variant "$prompt" "$i")"; done > "$WORK/m-$k.tsv"
        median_rows < "$WORK/m-$k.tsv" | awk -F'\t' -v row="$ROW" -v k="${k}K" \
            '{ printf row, "mlx", k, $1, sprintf("%.1f", $2), sprintf("%.0f", $3), sprintf("%.1f", $4), sprintf("%.1f", $5), sprintf("%.1f", $6) }'
        [ "$(wc -l < "$WORK/m-$k.tsv")" -ge 2 ] || printf "$ROW" mlx "${k}K" failed - - - - -
    fi
done
echo
echo "ollama* = follow-up sharing the prompt prefix (cache reuse); compare its prefill_s to the row above."
echo "mlx wall_s excludes model load (each mlx_lm.generate call is a new process)."
echo "ollama mem_GB is the loaded model + KV cache (/api/ps); mlx is mlx_lm's peak memory."
