#!/bin/bash
# Ciclo C1 (M2 do plano de segurança do EnchaT): Portainer e agent estavam
# fixados em ":latest" nas duas funções duplicadas de infra do secondary.sh
# (ferramenta_traefik_e_portainer e instalar_traefik_e_portainer) e no
# catálogo do painel; curlimages/curl:latest era usado 17x no secondary.sh
# (e ele recebe a senha do Portainer e o JWT como argumento de linha de
# comando, então a imagem merece ser fixa e íntegra). Este teste garante
# que:
#   1. nenhum ":latest" solto (fora de comentário) sobrevive nesses 3 lugares;
#   2. a tag do agent é IGUAL à tag do server nas duas funções duplicadas;
#   3. traefik-portainer.ts usa a MESMA versão que secondary.sh.
# Roda com: bash tests/test-imagens-pinadas.sh
set -u
cd "$(dirname "$0")/.."
falhas=0
falha() { echo "❌ FALHOU: $1"; falhas=$((falhas + 1)); }
ok() { echo "✅ $1"; }

# --- 1. Nenhum :latest solto (fora de comentário) nos 3 arquivos ---
# Considera "comentário" uma linha cujo primeiro caractere não-espaço é '#'.
grep_sem_comentario() {
  local arquivo="$1" padrao="$2"
  grep -nE "$padrao" "$arquivo" | grep -vE '^[0-9]+:[[:space:]]*#'
}

for arquivo in main.sh secondary.sh; do
  achados="$(grep_sem_comentario "$arquivo" 'portainer/agent:latest|portainer-ce:latest')"
  if [ -n "$achados" ]; then
    falha "$arquivo ainda tem portainer/agent:latest ou portainer-ce:latest fora de comentário:"
    echo "$achados"
  else
    ok "$arquivo sem portainer/agent:latest nem portainer-ce:latest"
  fi

  # curlimages/curl:latest OU curlimages/curl sem tag/digest (":" ou "@" depois do nome)
  achados_curl="$(grep_sem_comentario "$arquivo" 'curlimages/curl:latest')"
  if [ -n "$achados_curl" ]; then
    falha "$arquivo ainda tem curlimages/curl:latest fora de comentário:"
    echo "$achados_curl"
  else
    ok "$arquivo sem curlimages/curl:latest"
  fi

  # curlimages/curl sem ":" nem "@" na sequência (imagem sem tag = latest implícito)
  achados_sem_tag="$(grep_sem_comentario "$arquivo" 'curlimages/curl([^:@0-9A-Za-z._/-]|$)')"
  if [ -n "$achados_sem_tag" ]; then
    falha "$arquivo tem curlimages/curl sem tag/digest fora de comentário:"
    echo "$achados_sem_tag"
  else
    ok "$arquivo sem curlimages/curl sem tag/digest"
  fi
done

# --- 2. Tag do agent == tag do server, nas duas funções duplicadas ---
bloco_funcao() {
  local arquivo="$1" nome_funcao="$2"
  awk -v alvo="$nome_funcao" '
    $0 ~ "^" alvo "\\(\\)" { f = 1 }
    f { print }
    f && /^}$/ { exit }
  ' "$arquivo"
}

for funcao in ferramenta_traefik_e_portainer instalar_traefik_e_portainer; do
  bloco="$(bloco_funcao secondary.sh "$funcao")"
  if [ -z "$bloco" ]; then
    falha "função $funcao não encontrada em secondary.sh"
    continue
  fi

  # A proteção contra rebaixamento numa reinstalação só existe se a função
  # de fato chamar o resolvedor (ANTES do deploy) — sem isso, as variáveis
  # abaixo nunca seriam preenchidas e o heredoc quebraria ou usaria lixo.
  if ! printf '%s\n' "$bloco" | grep -q 'resolver_imagens_portainer '; then
    falha "$funcao: não chama resolver_imagens_portainer (sem proteção contra rebaixamento)"
    continue
  fi

  # E precisa vir ANTES do 'docker stack rm portainer': depois dele não há
  # Portainer para responder /api/system/status nem serviço para
  # 'docker service inspect', e a reinstalação cairia sempre na fixa —
  # rebaixando quem já roda uma versão maior.
  linha_resolver="$(printf '%s\n' "$bloco" | grep -nE '^[[:space:]]*resolver_imagens_portainer ' | head -1 | cut -d: -f1)"
  linha_rm="$(printf '%s\n' "$bloco" | grep -nE '^[[:space:]]*(sudo )?docker stack rm portainer' | head -1 | cut -d: -f1)"
  if [ -z "$linha_rm" ]; then
    falha "$funcao: não encontrei 'docker stack rm portainer' para conferir a ordem"
    continue
  fi
  if [ -z "$linha_resolver" ] || [ "$linha_resolver" -ge "$linha_rm" ]; then
    falha "$funcao: resolver_imagens_portainer precisa rodar ANTES de 'docker stack rm portainer' (resolver=${linha_resolver:-?}, rm=$linha_rm)"
    continue
  fi

  ref_agent="$(printf '%s\n' "$bloco" | grep -oE 'image: portainer/agent:[^[:space:]]+|image: \$\{IMAGEM_AGENT_PORTAINER\}' | sort -u)"
  ref_server="$(printf '%s\n' "$bloco" | grep -oE 'image: portainer/portainer-ce:[^[:space:]]+|image: \$\{IMAGEM_SERVER_PORTAINER\}' | sort -u)"

  if [ -z "$ref_agent" ] || [ -z "$ref_server" ]; then
    falha "$funcao: não encontrei as duas imagens (agent/server) para comparar"
    continue
  fi
  if [ "$(printf '%s\n' "$ref_agent" | wc -l)" -ne 1 ]; then
    falha "$funcao: a imagem do agent varia entre os dois heredocs (portainer-agent.yaml e portainer.yaml): $ref_agent"
    continue
  fi
  if [ "$(printf '%s\n' "$ref_server" | wc -l)" -ne 1 ]; then
    falha "$funcao: a imagem do server varia dentro da própria função: $ref_server"
    continue
  fi

  # Nunca um literal hardcoded — tem que vir das variáveis resolvidas por
  # resolver_imagens_portainer, senão a proteção contra rebaixamento é
  # ilusória (a função lê a versão em uso mas o heredoc ignora o resultado).
  if [[ "$ref_agent" != *'IMAGEM_AGENT_PORTAINER'* ]]; then
    falha "$funcao: imagem do agent não usa \${IMAGEM_AGENT_PORTAINER} (achado: $ref_agent)"
  elif [[ "$ref_server" != *'IMAGEM_SERVER_PORTAINER'* ]]; then
    falha "$funcao: imagem do server não usa \${IMAGEM_SERVER_PORTAINER} (achado: $ref_server)"
  else
    ok "$funcao: agent e server usam as imagens resolvidas por resolver_imagens_portainer"
  fi
done

# --- 3. traefik-portainer.ts usa a MESMA versão que secondary.sh ---
versao_shell="$(grep -oE '^PORTAINER_VERSION="[^"]+"' secondary.sh | head -1 | sed -E 's/^PORTAINER_VERSION="([^"]+)"$/\1/')"
versao_ts="$(grep -oE 'PORTAINER_VERSION = "[^"]+"' encha-setup-panel/src/lib/stacks/traefik-portainer.ts | head -1 | sed -E 's/.*"([^"]+)"$/\1/')"

if [ -z "$versao_shell" ]; then
  falha "PORTAINER_VERSION não encontrada em secondary.sh (fora das linhas 1-20)"
elif [ -z "$versao_ts" ]; then
  falha "PORTAINER_VERSION não encontrada em traefik-portainer.ts"
elif [ "$versao_shell" != "$versao_ts" ]; then
  falha "PORTAINER_VERSION diverge: secondary.sh=$versao_shell, traefik-portainer.ts=$versao_ts"
else
  ok "PORTAINER_VERSION igual nos dois lados ($versao_shell)"
fi

# --- 4. ENCHA_CURL_IMAGE: tag X.Y.Z + digest, e sempre usada entre aspas ---
# O curl recebe a senha do Portainer e o JWT na linha de comando: a imagem
# precisa ser íntegra (digest do índice multi-arch, não só a tag).
curl_img="$(grep -oE '^ENCHA_CURL_IMAGE="[^"]+"' secondary.sh | head -1 | sed -E 's/^ENCHA_CURL_IMAGE="([^"]+)"$/\1/')"
if ! [[ "$curl_img" =~ ^curlimages/curl:[0-9]+\.[0-9]+\.[0-9]+@sha256:[0-9a-f]{64}$ ]]; then
  falha "ENCHA_CURL_IMAGE precisa ser curlimages/curl:X.Y.Z@sha256:<64 hex> (achado: '${curl_img}')"
else
  ok "ENCHA_CURL_IMAGE fixa por tag + digest"
fi
if sed -n '1,20p' secondary.sh | grep -q '^ENCHA_CURL_IMAGE='; then
  falha "ENCHA_CURL_IMAGE está nas linhas 1-20 do secondary.sh (reservadas ao ENCHA_VERSION)"
fi

for arquivo in main.sh secondary.sh; do
  sem_aspas="$(grep_sem_comentario "$arquivo" '\$\{?ENCHA_CURL_IMAGE' | grep -E '(^|[^"])\$\{?ENCHA_CURL_IMAGE')"
  if [ -n "$sem_aspas" ]; then
    falha "$arquivo usa ENCHA_CURL_IMAGE sem aspas:"
    echo "$sem_aspas"
  else
    ok "$arquivo: ENCHA_CURL_IMAGE sempre entre aspas"
  fi
done

# PORTAINER_VERSION não pode estar nas primeiras 20 linhas do secondary.sh
# (reservadas ao ENCHA_VERSION / set-version.sh).
if sed -n '1,20p' secondary.sh | grep -q '^PORTAINER_VERSION='; then
  falha "PORTAINER_VERSION está nas linhas 1-20 do secondary.sh (reservadas ao ENCHA_VERSION)"
fi

[ "$falhas" -eq 0 ] || exit 1
