#!/usr/bin/env bash
# cron이 5분마다 부르는 진입점. 잠금 → 저장소 동기화 → 최신 작업 스크립트 실행.
export PATH="$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin"
S="$HOME/.lob_worker"; mkdir -p "$S"
exec 9>"$S/lock"
flock -n 9 || exit 0

R="${LOB_REPO:-$HOME/lob}"
cd "$R" || { echo "$(date '+%F %T') repo not found: $R"; exit 1; }

if ! git pull --rebase -q 2>"$S/pull.err"; then
  git rebase --abort 2>/dev/null
  git fetch -q origin && git reset -q --hard origin/main
  echo "$(date '+%F %T') pull failed, reset to origin/main: $(tr '\n' ' ' < "$S/pull.err")"
fi

# 실행 중인 파일이 git pull로 바뀌지 않도록 복사본을 실행한다
cp pipeline/instance/lob_worker.sh "$S/run.sh"
exec bash "$S/run.sh"
