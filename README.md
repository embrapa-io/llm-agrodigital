# LLM Stack — GPU Server do CNPTIA (llm.agrodigital.agro.rocks)

Stack de inferência LLM do GPU server dedicado aos clusters de deploy do
CNPTIA (`agrodigital1`/`agrodigital2.agro.rocks`), derivada de
[embrapa-io/llm](https://github.com/embrapa-io/llm) (GPU servers da Sede).
Hardware modesto — 2× **RTX 3070 8 GB (Ampere, sm_86)** — então o dimensionamento
é o inverso dos L40S: modelo pequeno em AWQ INT4, contexto calibrado pelo KV
disponível. Engine padrão: **SGLang** (TP=2); vLLM fica sob profile como
fallback.

| | |
|---|---|
| **Host** | `llm.agrodigital.agro.rocks` (192.168.0.10, rede interna dos clusters) |
| **Papel** | LLM para builds em desenvolvimento nos clusters agrodigital1/2 |

## Hardware

- **Máquina:** workstation bare metal (ex-VM `EmbrapaIO-GPU` — a VM foi
  eliminada na atualização do CloudStack do CNPTIA, que aboliu o GPU
  passthrough; jun–jul/2026)
- **GPUs:** 2× NVIDIA **GeForce RTX 3070 8 GB** (Ampere, sm_86) — 16 GB de
  VRAM somados via TP=2; **sem FP8 nativo** (Ada/Hopper+), **sem NVLink/P2P**
- **CPU / RAM / disco:** ⚠️ a inventariar (`lscpu`, `free -h`, `df -h`) —
  recalibrar o tuning do Ollama no `.env` após o inventário
- **SO:** Ubuntu (instalação limpa da migração)

## Arquitetura

```
llm.agrodigital.agro.rocks
├── GPU 0 (RTX 3070 8 GB) ──┐
│                            ├── SGLang TP=2: Qwen3-VL-8B-Instruct AWQ INT4
├── GPU 1 (RTX 3070 8 GB) ──┘   multimodal (texto+imagem), 32K de contexto
│                                (65K com KV FP8 — ver .env; medir no boot)
│
└── CPU ──── Ollama: embeddings (bge-m3, qwen3-embedding, embeddinggemma)

nginx (porta 80 — URL única para os clientes):
  /v1/*  → SGLang :30000 (OpenAI-compatible: chat, visão, tools)
  /api/* → Ollama :11434 (API nativa: embeddings)
porta 11435 → engine direto (diagnóstico)
```

⚠️ **GeForce não tem P2P**: todo engine com TP=2 precisa de
`NCCL_P2P_DISABLE=1` (default no compose) — mesma lição dos hp-gpu01/02, onde
o primeiro coletivo do TP=2 travava com GPU a 100% até o watchdog matar o
processo.

## Modelo servido nas GPUs

**[cyankiwi/Qwen3-VL-8B-Instruct-AWQ-4bit](https://huggingface.co/cyankiwi/Qwen3-VL-8B-Instruct-AWQ-4bit)**
(AWQ INT4 do [Qwen/Qwen3-VL-8B-Instruct](https://huggingface.co/Qwen/Qwen3-VL-8B-Instruct),
Apache 2.0, ~6,5 GiB):

- **Denso 8B multimodal** — visão forte na classe (DocVQA 96.1, OCR em 32
  idiomas, GUI grounding), tool calling, ótimo pt-BR
- **AWQ INT4 via Marlin** — caminho performático em Ampere sm_86; deixa
  ~5–6 GiB de pool de KV para contexto
- Contexto nativo 262K; aqui **32K** (limite do KV em 16 GB), com rota para
  65K via KV FP8 (`--kv-cache-dtype fp8_e5m2` — storage E5M2 funciona em
  Ampere; validar qualidade)
- Mesma família Qwen dos demais GPU servers da plataforma — coerência de
  parsers, template e comportamento para os clientes

Racional (ago/2026): **não existe Qwen3.6 pequeno** (lineup: 27B e 35B-A3B;
o 27B-AWQ tem ~15,5 GiB e não cabe com KV). GLM-4.7-Flash (17–20 GiB, text-only)
não cabe. **PrismML Bonsai 27B** (1-bit/ternário do Qwen3.6-27B, 3,9–5,9 GiB)
caberia com folga, mas roda apenas no fork de llama.cpp do PrismML — sem
SGLang/vLLM e sem VL confirmado; fica na watch list (se os kernels chegarem
ao llama.cpp/Ollama mainline, reavaliar). Alternativas na prateleira:
`Qwen3-VL-4B` (mais contexto/slots) e FP8-Marlin do 8B (mais qualidade,
menos KV).

## Setup do servidor do zero

```bash
# 1. Provisionar (driver NVIDIA, Docker CE oficial, NVIDIA Container Toolkit)
sudo bash setup/provision.sh
sudo reboot

# 2. Clonar a stack
sudo mkdir -p /data && sudo chown $USER: /data
git clone https://github.com/embrapa-io/llm-agrodigital.git /data/llm-agrodigital
cd /data/llm-agrodigital
cp .env.example .env    # revisar valores

# 3. Rede externa do compose (compartilhável com outras stacks do host)
docker network create llm

# 4. Baixar o modelo (~6,5 GiB)
./download-model.sh

# 5. Subir
docker compose up -d --build
docker compose logs -f sglang
```

No boot do SGLang, anotar `max_total_num_tokens` (capacidade real de KV) e
ajustar `SGLANG_CONTEXT_LENGTH`/`SGLANG_MAX_RUNNING_REQUESTS` no `.env` —
a conta estimada está comentada lá.

## Endpoints

| Uso | URL |
|---|---|
| Chat/visão/tools (OpenAI-compatible) | `http://llm.agrodigital.agro.rocks/v1` |
| Embeddings (API nativa Ollama) | `http://llm.agrodigital.agro.rocks/api/embed` |
| Engine direto (diagnóstico) | `http://llm.agrodigital.agro.rocks:11435/v1` |

O hostname resolve pelo DNS público da zona `agro.rocks` para o IP interno
(192.168.0.10) — alcançável apenas pelas VMs da rede interna do CNPTIA
(de propósito: containers Docker dos clusters resolvem sem `extra_hosts`).

- Clientes OpenAI usam key dummy (ex.: `sk-local`).
- Endpoints de administração do Ollama (`/api/pull`, `/api/delete`, ...) são
  bloqueados no nginx (403) — usar `docker compose exec ollama ollama pull ...`.

## Modelos Ollama (CPU — embeddings)

Curadoria mínima (subconjunto da usada nos servers da Sede):

```bash
docker compose exec ollama ollama pull bge-m3              # principal (RAG pt-BR)
docker compose exec ollama ollama pull qwen3-embedding:0.6b
docker compose exec ollama ollama pull embeddinggemma:300m
```

## Operação

```bash
./update.sh                      # git pull + rebuild + prune (rotina de update)
./monitor.sh                     # nvidia-smi em loop (via container)
./tunnel.sh                      # da estação: 11434/11435 locais → servidor
docker compose logs -f sglang    # logs do engine
```

### Fallback vLLM (profile)

O serviço `vllm` fica sob profile (mesma porta do SGLang — não rodam juntos).
Se o SGLang apresentar problema neste hardware:

```bash
docker compose stop sglang
docker compose --profile vllm up -d vllm
# trocar o upstream do nginx.conf para vllm:8000 e:
docker compose restart nginx
```

## Pendências

- [ ] Inventário de CPU/RAM/disco → recalibrar Ollama no `.env`
- [ ] Medir `max_total_num_tokens` no 1º boot → fixar contexto/slots
- [ ] Validar visão (imagem base64) e tool calling (parser `qwen25`)
- [ ] Avaliar KV FP8 (`fp8_e5m2`) → contexto 65K
- [ ] Observabilidade: Alloy (journal + node exporter) + plugin Loki do
  Docker, `host=llm.agrodigital.agro.rocks` — depois ativar o host no Gatus
  (grupo "GPU Servers", já commitado no repo grafana)
