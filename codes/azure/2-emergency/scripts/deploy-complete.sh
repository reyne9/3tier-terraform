#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bash "$SCRIPT_DIR/deploy-petclinic.sh"
bash "$SCRIPT_DIR/setup-ingress.sh" "$@"
echo "애플리케이션 연결 완료. DB 복원과 읽기·쓰기 검증 후 DR 트래픽을 전환하세요."
