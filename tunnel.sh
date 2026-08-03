#!/bin/bash
#
# Encaminhamento de portas para o GPU server do CNPTIA. O host (192.168.0.10)
# fica na rede interna dos clusters — o acesso da estação exige salto pelo
# agrodigital1 (SSH na porta 10022). Configurar no ~/.ssh/config:
#
#   Host agrodigital1
#       HostName agrodigital1.agro.rocks
#       Port 10022
#       User root
#
#   Host llm-agrodigital
#       HostName 192.168.0.10
#       User m354215
#       ProxyJump agrodigital1
#
# O túnel expõe localmente a 11434 (nginx: /v1 GPU + /api Ollama) e a 11435
# (SGLang direto).
#
# Uso:
#   ./tunnel.sh          # abre (idempotente) e testa /v1/models
#   ./tunnel.sh down     # encerra
#   ./tunnel.sh status   # verifica túnel + endpoint

set -euo pipefail

HOST="${1:-llm-agrodigital}"
CTRL="${HOME}/.ssh/ctl-llm-agrodigital-tunnel.sock"

is_up() { ssh -O check -S "$CTRL" dummy 2>/dev/null; }

probe() {
  echo "→ GET http://localhost:11435/v1/models"
  curl -sf --max-time 5 "http://localhost:11435/v1/models" && echo || {
    echo "✗ endpoint não respondeu (túnel ok ≠ SGLang no ar — conferir logs no servidor)"
    return 1
  }
}

case "$HOST" in
  down)
    is_up && ssh -O exit -S "$CTRL" dummy 2>/dev/null || true
    echo "✓ túnel encerrado"
    ;;
  status)
    if is_up; then echo "✓ túnel ativo"; probe; else echo "✗ túnel inativo"; fi
    ;;
  llm-agrodigital)
    if is_up; then
      echo "✓ túnel já ativo"
    else
      ssh -f -N -M -S "$CTRL" \
        -L 11434:localhost:11434 \
        -L 11435:localhost:11435 \
        "$HOST"
      echo "✓ túnel aberto para $HOST (11434 nginx, 11435 SGLang)"
    fi
    probe
    ;;
  *)
    echo "Uso: $0 [llm-agrodigital|down|status]" >&2
    exit 1
    ;;
esac
