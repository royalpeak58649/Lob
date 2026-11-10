#!/usr/bin/env bash
# 인스턴스 설치. 사용법:
#   bash install.sh key      배포 키 생성, 저장소 설정 (공개 키 출력)
#   bash install.sh finish   GitHub 연결 확인, 예약 실행 등록
set -u
REPO_SLUG="royalpeak58649/Lob"
R="${LOB_REPO:-$HOME/lob}"
S="$HOME/.lob_worker"
K="$HOME/.ssh/lob_deploy"
mkdir -p "$S" "$HOME/.ssh"; chmod 700 "$HOME/.ssh"

case "${1:-}" in
key)
  [ -f "$K" ] || ssh-keygen -q -t ed25519 -N '' -C "lob-art-worker@$(hostname)" -f "$K"
  if ! grep -q '^Host github-lob$' "$HOME/.ssh/config" 2>/dev/null; then
    printf '\nHost github-lob\n  HostName github.com\n  User git\n  IdentityFile %s\n  IdentitiesOnly yes\n' "$K" >> "$HOME/.ssh/config"
    chmod 600 "$HOME/.ssh/config"
  fi
  grep -q '^github.com ' "$HOME/.ssh/known_hosts" 2>/dev/null || ssh-keyscan -t ed25519 github.com >> "$HOME/.ssh/known_hosts" 2>/dev/null
  git -C "$R" remote set-url origin "git@github-lob:$REPO_SLUG.git"
  git -C "$R" config user.name "Lob Art Worker"
  git -C "$R" config user.email "lob-art-worker@users.noreply.github.com"
  echo "PUBKEY: $(cat "$K.pub")"
  ;;
finish)
  out="$(ssh -T github-lob 2>&1)"
  echo "$out" | grep -q "successfully authenticated" || { echo "CHECK_FAIL: GitHub 인증 실패: $out"; exit 1; }
  git -C "$R" fetch -q origin || { echo "CHECK_FAIL: fetch 실패"; exit 1; }
  git -C "$R" push --dry-run -q origin HEAD:main 2>"$S/dry.err" || { echo "CHECK_FAIL: 쓰기 권한 없음 (Allow write access 체크 확인): $(cat "$S/dry.err")"; exit 1; }
  cp "$R/pipeline/instance/cron_runner.sh" "$S/cron.sh"
  ( crontab -l 2>/dev/null | grep -v 'lob_worker_cron'
    echo "*/5 * * * * bash $S/cron.sh >> $S/worker.log 2>&1 # lob_worker_cron" ) | crontab -
  echo "CHECK_OK"
  ;;
*)
  echo "usage: install.sh key|finish"; exit 2 ;;
esac
