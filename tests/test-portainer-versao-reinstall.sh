#!/bin/bash
# Ciclo C1 (M2 do plano de segurança do EnchaT): proteção contra rebaixamento
# do Portainer numa reinstalação. Antes de remover/recriar a stack, o
# secondary.sh lê a versão hoje em execução (resolver_imagens_portainer) e:
#   - versão em uso MAIOR que a fixa -> implanta a versão em uso (nunca rebaixa);
#   - versão em uso MENOR OU IGUAL   -> implanta a fixa (PORTAINER_VERSION);
#   - leitura falha (erro/vazio)     -> reusa a imagem completa em uso, sem
#     tentar adivinhar.
# Roda as funções REAIS (extraídas de secondary.sh) com docker/sudo FALSOS
# no PATH, e afirma qual imagem cada cenário decide implantar.
# Roda com: bash tests/test-portainer-versao-reinstall.sh
set -u
cd "$(dirname "$0")/.."
falhas=0
falha() { echo "❌ FALHOU: $1"; falhas=$((falhas + 1)); }
ok() { echo "✅ $1"; }

PORTAINER_VERSION="$(grep -oE '^PORTAINER_VERSION="[^"]+"' secondary.sh | head -1 | sed -E 's/^PORTAINER_VERSION="([^"]+)"$/\1/')"
if [ -z "$PORTAINER_VERSION" ]; then
  echo "❌ FALHOU: PORTAINER_VERSION não encontrada em secondary.sh — rode depois de implementar o C1"
  exit 1
fi
ENCHA_CURL_IMAGE="$(grep -oE '^ENCHA_CURL_IMAGE="[^"]+"' secondary.sh | head -1 | sed -E 's/^ENCHA_CURL_IMAGE="([^"]+)"$/\1/')"
if [ -z "$ENCHA_CURL_IMAGE" ]; then
  echo "❌ FALHOU: ENCHA_CURL_IMAGE não encontrada em secondary.sh — rode depois de implementar o C1"
  exit 1
fi

extrair_funcao() {
  local nome="$1"
  awk -v alvo="$nome" '
    $0 ~ "^" alvo "\\(\\) \\{$" { f = 1 }
    f { print }
    f && /^\}$/ { exit }
  ' secondary.sh
}

fn_semver="$(extrair_funcao versao_semver_maior)"
fn_resolver="$(extrair_funcao resolver_imagens_portainer)"

if [ -z "$fn_semver" ]; then
  echo "❌ FALHOU: função versao_semver_maior não encontrada em secondary.sh"
  exit 1
fi
if [ -z "$fn_resolver" ]; then
  echo "❌ FALHOU: função resolver_imagens_portainer não encontrada em secondary.sh"
  exit 1
fi

# --- Ambiente com docker/sudo falsos no PATH ---
BINDIR="$(mktemp -d)"
trap 'rm -rf "$BINDIR"' EXIT

cat > "$BINDIR/sudo" <<'EOSUDO'
#!/bin/bash
exec "$@"
EOSUDO
chmod +x "$BINDIR/sudo"

# FAKE_DOCKER_MODE controla o que o "docker run" (chamada curl-em-container
# contra /api/system/status) devolve; FAKE_IMG_AGENT/FAKE_IMG_SERVER
# controlam o que "docker service inspect" devolve (imagem completa em uso).
cat > "$BINDIR/docker" <<'EODOCKER'
#!/bin/bash
case "$1" in
  run)
    case "${FAKE_DOCKER_MODE:-}" in
      maior) echo '{"Version":"2.46.0"}' ;;
      menor) echo '{"Version":"2.40.0"}' ;;
      falha) : ;;
      *) : ;;
    esac
    ;;
  service)
    if [ "$2" = "inspect" ]; then
      case "$3" in
        portainer_agent) echo "${FAKE_IMG_AGENT:-}" ;;
        portainer_portainer) echo "${FAKE_IMG_SERVER:-}" ;;
      esac
    fi
    ;;
esac
exit 0
EODOCKER
chmod +x "$BINDIR/docker"

rodar_cenario() {
  # Roda resolver_imagens_portainer num subshell isolado (com o PATH falso)
  # e imprime "IMAGEM_AGENT_PORTAINER=<x>|IMAGEM_SERVER_PORTAINER=<y>".
  (
    export PATH="$BINDIR:$PATH"
    export PORTAINER_VERSION ENCHA_CURL_IMAGE
    export FAKE_DOCKER_MODE="${1:-}" FAKE_IMG_AGENT="${2:-}" FAKE_IMG_SERVER="${3:-}"
    eval "$fn_semver"
    eval "$fn_resolver"
    resolver_imagens_portainer "rede-teste" true
    echo "IMAGEM_AGENT_PORTAINER=$IMAGEM_AGENT_PORTAINER|IMAGEM_SERVER_PORTAINER=$IMAGEM_SERVER_PORTAINER"
  )
}

# --- Cenário 1: versão em uso MAIOR que a fixa -> implanta a MAIOR ---
saida="$(rodar_cenario maior)"
esperado="IMAGEM_AGENT_PORTAINER=portainer/agent:2.46.0|IMAGEM_SERVER_PORTAINER=portainer/portainer-ce:2.46.0"
if [ "$saida" = "$esperado" ]; then
  ok "versão em uso maior (2.46.0 > $PORTAINER_VERSION) -> implanta a maior"
else
  falha "versão em uso maior: esperado '$esperado', obtido '$saida'"
fi

# --- Cenário 2: versão em uso MENOR (ou igual) -> implanta a FIXA ---
saida="$(rodar_cenario menor)"
esperado="IMAGEM_AGENT_PORTAINER=portainer/agent:${PORTAINER_VERSION}|IMAGEM_SERVER_PORTAINER=portainer/portainer-ce:${PORTAINER_VERSION}"
if [ "$saida" = "$esperado" ]; then
  ok "versão em uso menor (2.40.0 < $PORTAINER_VERSION) -> implanta a fixa"
else
  falha "versão em uso menor: esperado '$esperado', obtido '$saida'"
fi

# --- Cenário 2b: versão em uso IGUAL à fixa -> implanta a FIXA (não é "maior") ---
saida="$(FAKE_DOCKER_MODE_VERSION_IGUAL=1 rodar_cenario igual)"
# "igual" não é um modo conhecido do docker fake (cai no default vazio) — em
# vez disso, testamos igualdade forçando o modo "menor" mas comparando com a
# própria PORTAINER_VERSION via versao_semver_maior diretamente.
(
  eval "$fn_semver"
  if versao_semver_maior "$PORTAINER_VERSION" "$PORTAINER_VERSION"; then
    echo "❌ FALHOU: versao_semver_maior considerou uma versão maior que ela mesma"
    exit 1
  fi
) && ok "versao_semver_maior: versão igual não é considerada maior" || falhas=$((falhas + 1))

# --- Cenário 3: leitura falha (erro/vazio) -> reusa a imagem completa em uso ---
saida="$(rodar_cenario falha "portainer/agent:2.44.9" "portainer/portainer-ce:2.44.9")"
esperado="IMAGEM_AGENT_PORTAINER=portainer/agent:2.44.9|IMAGEM_SERVER_PORTAINER=portainer/portainer-ce:2.44.9"
if [ "$saida" = "$esperado" ]; then
  ok "leitura falhou -> reusa a imagem completa (com tag) já em uso"
else
  falha "leitura falhou: esperado '$esperado', obtido '$saida'"
fi

[ "$falhas" -eq 0 ] || exit 1
