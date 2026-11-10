#!/usr/bin/env bash
# 그림 요청(art/requests/*.txt)을 agy로 생성해 art/raw/에 올린다.
# cron_runner.sh가 잠금과 저장소 동기화를 끝낸 뒤 호출한다.
set -u
export PATH="$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin"

R="${LOB_REPO:-$HOME/lob}"
S="$HOME/.lob_worker"
DAILY_MAX="${LOB_DAILY_MAX:-30}"   # 하루 최대 생성 수 (구독 한도 보호)
PER_RUN="${LOB_PER_RUN:-3}"        # 한 번 실행에 최대 생성 수
MAX_TRIES=3
GEN_TIMEOUT=540
BRAIN="$HOME/.gemini/antigravity-cli/brain"

mkdir -p "$S/tries" "$S/work"
cd "$R" || exit 1
log(){ echo "$(date '+%F %T') $*"; }

# 로그가 1MB를 넘으면 뒤쪽만 남긴다
if [ -f "$S/worker.log" ] && [ "$(stat -c %s "$S/worker.log")" -gt 1048576 ]; then
  tail -n 2000 "$S/worker.log" > "$S/worker.log.tmp" && mv "$S/worker.log.tmp" "$S/worker.log"
fi

TODAY_FILE="$S/count-$(date +%F)"
today=$(cat "$TODAY_FILE" 2>/dev/null || echo 0)
find "$S" -maxdepth 1 -name 'count-*' -mtime +7 -delete 2>/dev/null

done_names=()
made=0

shopt -s nullglob
for req in art/requests/*.txt; do
  name="$(basename "$req" .txt)"
  [[ "$name" =~ ^[A-Za-z0-9_-]+$ ]] || { log "skip bad name: $name"; continue; }
  compgen -G "art/raw/$name.*" >/dev/null && continue        # 이미 결과(또는 오류 기록)가 있음
  [ "$made" -ge "$PER_RUN" ] && break
  if [ "$today" -ge "$DAILY_MAX" ]; then log "daily limit $DAILY_MAX reached"; break; fi

  pf="$S/work/$name.prompt"
  {
    echo "Use your built-in image generation tool to create exactly one image."
    echo "Do not run any terminal commands and do not move, copy or rename files. Just generate the image, then reply DONE."
    echo
    cat art/style.txt 2>/dev/null
    echo
    echo "Subject: $(cat "$req")"
  } > "$pf"

  raw="$S/work/$name.raw"
  marker="$S/work/$name.start"
  touch "$marker"; sleep 1
  start=$(date +%s)
  ( cd "$S/work" && timeout -k 10 "$GEN_TIMEOUT" \
      script -qec "agy --output-format json --print-timeout 8m -p \"\$(cat '$pf')\"" "$raw" </dev/null >/dev/null 2>&1 )
  rc=$?
  secs=$(( $(date +%s) - start ))
  today=$((today + 1)); echo "$today" > "$TODAY_FILE"

  cid="$(tr -d '\r' < "$raw" | grep -o '"conversation_id":"[^"]*"' | head -n 1 | cut -d'"' -f4)"
  img=""
  if [ -n "$cid" ] && [ -d "$BRAIN/$cid" ]; then
    img="$(find "$BRAIN/$cid" -maxdepth 3 -type f \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.webp' \) -newer "$marker" -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -n 1 | cut -d' ' -f2-)"
  fi
  if [ -z "$img" ]; then
    img="$(find "$BRAIN" -type f \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.webp' \) -newer "$marker" -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -n 1 | cut -d' ' -f2-)"
  fi

  if [ -n "$img" ]; then
    ext="${img##*.}"; ext="$(echo "$ext" | tr 'A-Z' 'a-z')"; [ "$ext" = "jpeg" ] && ext=jpg
    cp "$img" "art/raw/$name.$ext"
    python3 - "art/raw/$name.json" "$cid" "$secs" "$req" "$(agy --version 2>/dev/null | head -n 1)" "$(file -b "$img" | grep -o '[0-9]\+x[0-9]\+' | tail -n 1)" <<'PY'
import hashlib, json, sys, datetime
out, cid, secs, req, ver, size = sys.argv[1:7]
json.dump({
    "conversation_id": cid,
    "seconds": int(secs),
    "generated_at": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
    "request_sha256": hashlib.sha256(open(req, "rb").read()).hexdigest(),
    "size": size,
    "agy_version": ver,
}, open(out, "w"), indent=2, ensure_ascii=False)
PY
    rm -f "$S/tries/$name"
    done_names+=("$name")
    made=$((made + 1))
    log "OK $name (${secs}s, $(file -b "$img" | grep -o '[0-9]\+x[0-9]\+' | tail -n 1))"
  else
    tries=$(( $(cat "$S/tries/$name" 2>/dev/null || echo 0) + 1 ))
    echo "$tries" > "$S/tries/$name"
    log "FAIL $name try $tries rc=$rc cid=${cid:-none}"
    if [ "$tries" -ge "$MAX_TRIES" ]; then
      {
        echo "failed $tries times, last at $(date -u '+%F %T UTC'), rc=$rc, conversation_id=${cid:-none}"
        echo "--- agy output (tail) ---"
        tr -d '\r' < "$raw" | tail -c 3000
      } > "art/raw/$name.error.txt"
      rm -f "$S/tries/$name"
      done_names+=("$name(error)")
    fi
  fi
  rm -f "$marker"
done

if [ "${#done_names[@]}" -gt 0 ]; then
  git add art/raw
  git commit -q -m "art: ${done_names[*]}" || exit 0
  for i in 1 2 3; do
    if git push -q origin HEAD:main 2>"$S/push.err"; then log "pushed: ${done_names[*]}"; exit 0; fi
    git pull --rebase -q || { git rebase --abort 2>/dev/null; }
    sleep $((i * 5))
  done
  log "push failed: $(tr '\n' ' ' < "$S/push.err")"
fi
