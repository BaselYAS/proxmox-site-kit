# shellcheck shell=bash
# Progress output shared by site-kit.sh and site-kit-relocate.sh (sourced by the worker).
# The worker's stdout is the full log (raw apt/curl detail). Lines meant for the person watching also go to
# $SK_SCREEN, which is what the window shows. Step scripts (run as child bash) get show/note/skipped exported.
#   plan N          total number of steps
#   part "title" cmd args…   runs one numbered step with a 30 s "still working" line, records OK/FAILED/SKIPPED
#   recap           one line per step + total time
SK_T0=$(date +%s); SK_I=0; SK_N=0; SK_RECAP=()
export SK_SCREEN=${SK_SCREEN:-/root/site-kit.screen}
export SK_NOW=${SK_SCREEN%.screen}.now SK_SKIPF=${SK_SCREEN%.screen}.skipped
dur(){ local s=$1; if [ "$s" -ge 60 ]; then printf '%dm%02ds' $((s/60)) $((s%60)); else printf '%ds' "$s"; fi; }
show(){ printf '%s\n' "$*"; printf '%s\n' "$*" >> "$SK_SCREEN"; }      # log + screen
note(){ show "      $*"; printf '%s' "$*" > "$SK_NOW"; }                 # sub-step (also "what is it doing now")
skipped(){ echo "      $*"; printf '%s' "$*" > "$SK_SKIPF"; }                  # the step had nothing to do
export -f show note skipped
plan(){ SK_N=$1; }
part(){ local title=$1 t0 rc last now el st; shift; SK_I=$((SK_I+1)); t0=$(date +%s); last=$t0
  : > "$SK_SKIPF"; printf '%s' "$title" > "$SK_NOW"
  show ""; show "[$SK_I/$SK_N] $title…"; echo "--- $title ($(date '+%F %T'))"
  "$@" & local p=$!
  while kill -0 "$p" 2>/dev/null; do sleep 1; now=$(date +%s)
    if [ $((now-last)) -ge 30 ]; then last=$now; show "      still working… $(cat "$SK_NOW" 2>/dev/null) (elapsed $(dur $((now-t0))))"; fi; done
  wait "$p"; rc=$?; el=$(dur $(( $(date +%s)-t0 )))
  if [ $rc = 0 ] && [ -s "$SK_SKIPF" ]; then st=SKIPPED; show "[$SK_I/$SK_N] SKIPPED: $(cat "$SK_SKIPF") ($el)"
  elif [ $rc = 0 ]; then st=OK; show "[$SK_I/$SK_N] OK ($el)"
  else st=FAILED; show "[$SK_I/$SK_N] FAILED rc=$rc ($el) (see ${LOG:-the log}, search \"--- $title\")"; fi
  echo "--- $title rc=$rc"
  SK_RECAP+=("$(printf ' %-8s %-7s %s' "$st" "$el" "$title")"); return $rc; }
recap(){ show ""; show "== Recap"; local l; for l in "${SK_RECAP[@]}"; do show "$l"; done
  show " total time $(dur $(( $(date +%s)-SK_T0 )))"; rm -f "$SK_NOW" "$SK_SKIPF"; }
