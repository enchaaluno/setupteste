#!/bin/bash
# Ciclo C9 (M3 do plano de segurança do EnchaT): segredos do Docker por trás
# de PANEL_ADMIN_PASSWORD/PORTAINER_PASSWORD — deploy_stack_painel_via_portainer
# passa a montar Docker secrets versionados ("<base>_<epoch>") quando a
# imagem que vai rodar tiver o label com.encha.painel.recursos=
# "credenciais-arquivo ..." (C4), esvaziando a senha em texto do env_json e
# apontando *_FILE/_SECRET_NAME pro mount certo — mas SÓ quando o secret foi
# criado com sucesso NESTA rodada. Ver garantir_segredos_credenciais_painel/
# limpar_segredos_antigos_painel/imagem_painel_tem_label_credenciais_arquivo
# em secondary.sh.
#
# Roda as funções REAIS (extraídas de secondary.sh) com docker/jq/openssl no
# PATH — jq real (ou stub, como os outros testes), docker e openssl FALSOS
# (openssl falso só porque não precisamos de aleatoriedade de verdade pro
# conteúdo do secret "bootstrap" — o teste não olha esse conteúdo).
#
# Roda com: bash tests/test-painel-segredos.sh
set -u
cd "$(dirname "$0")/.." || exit 1
falhas=0
falha() { echo "❌ FALHOU: $1"; falhas=$((falhas + 1)); }
ok() { echo "✅ $1"; }

extrair_funcao() {
  local nome="$1"
  awk -v alvo="$nome" '
    $0 ~ "^" alvo "\\(\\) \\{$" { f = 1 }
    f { print }
    f && /^\}$/ { exit }
  ' secondary.sh
}

fn_imagem="$(extrair_funcao imagem_painel_tem_label_credenciais_arquivo)"
fn_garantir="$(extrair_funcao garantir_segredos_credenciais_painel)"
fn_limpar="$(extrair_funcao limpar_segredos_antigos_painel)"
fn_deploy="$(extrair_funcao deploy_stack_painel_via_portainer)"

for par in "fn_imagem:imagem_painel_tem_label_credenciais_arquivo" \
           "fn_garantir:garantir_segredos_credenciais_painel" \
           "fn_limpar:limpar_segredos_antigos_painel" \
           "fn_deploy:deploy_stack_painel_via_portainer"; do
  var="${par%%:*}"; nome="${par#*:}"
  if [ -z "${!var}" ]; then
    echo "❌ FALHOU: função $nome não encontrada em secondary.sh — rode depois de implementar o C9"
    exit 1
  fi
done

ENCHA_VERSION="0.3.5"
ENCHA_CURL_IMAGE="$(grep -oE '^ENCHA_CURL_IMAGE="[^"]+"' secondary.sh | head -1 | sed -E 's/^ENCHA_CURL_IMAGE="([^"]+)"$/\1/')"
if [ -z "$ENCHA_CURL_IMAGE" ]; then
  echo "❌ FALHOU: ENCHA_CURL_IMAGE não encontrada em secondary.sh (C1)"
  exit 1
fi

# --- Ambiente com docker/jq falsos no PATH ---
BINDIR="$(mktemp -d)"
trap 'rm -rf "$BINDIR"' EXIT

if command -v jq >/dev/null 2>&1; then
  JQ_REAL="$(command -v jq)"
  cat > "$BINDIR/jq" <<EOJQREAL
#!/bin/bash
exec "$JQ_REAL" "\$@"
EOJQREAL
  chmod +x "$BINDIR/jq"
else
  echo "❌ FALHOU: este teste precisa de jq real no PATH (usado dos dois lados: montar E ler o env_json)"
  exit 1
fi

cat > "$BINDIR/openssl" <<'EOSSL'
#!/bin/bash
# Só usado por garantir_segredos_credenciais_painel pro conteúdo descartável
# do secret "bootstrap" — o teste nunca olha esse conteúdo.
printf 'conteudo-descartavel-bootstrap'
exit 0
EOSSL
chmod +x "$BINDIR/openssl"

# "docker" falso: entende 'image inspect', 'secret {inspect,create,rm,ls}' e
# 'run' (o curl-em-container contra a API do Portainer, como os outros
# testes de secondary.sh já fazem).
cat > "$BINDIR/docker" <<'EODOCKER'
#!/bin/bash
[ -n "${FAKE_LOG:-}" ] && echo "$*" >> "$FAKE_LOG"

sub="${1:-}"

if [ "$sub" = "image" ] && [ "${2:-}" = "inspect" ]; then
    printf '%s' "${FAKE_IMAGE_LABEL:-}"
    exit 0
fi

if [ "$sub" = "secret" ]; then
    case "${2:-}" in
      inspect)
        nome="${3:-}"
        [ -f "${FAKE_SECRETS_FILE:-/dev/null}" ] && grep -qxF "$nome" "$FAKE_SECRETS_FILE" 2>/dev/null && exit 0
        exit 1
        ;;
      create)
        shift 2
        nome="" rotulo=""
        while [ "$#" -gt 0 ]; do
          case "$1" in
            --label) rotulo="${2:-}"; shift 2 ;;
            -) shift ;;
            *) [ -z "$nome" ] && nome="$1"; shift ;;
          esac
        done
        conteudo="$(cat)"
        if [ "${FAKE_SECRET_CREATE_FALHA:-false}" = true ]; then
            exit 1
        fi
        if [ -f "${FAKE_SECRETS_FILE:-/dev/null}" ] && grep -qxF "$nome" "$FAKE_SECRETS_FILE" 2>/dev/null; then
            exit 1
        fi
        [ -n "${FAKE_SECRETS_FILE:-}" ] && echo "$nome" >> "$FAKE_SECRETS_FILE"
        if [ -n "${FAKE_SECRETS_CONTEUDO_DIR:-}" ]; then
            mkdir -p "$FAKE_SECRETS_CONTEUDO_DIR"
            printf '%s' "$conteudo" > "$FAKE_SECRETS_CONTEUDO_DIR/$nome"
        fi
        if [ -n "$rotulo" ] && [ -n "${FAKE_SECRETS_LABELS_FILE:-}" ]; then
            echo "$nome $rotulo" >> "$FAKE_SECRETS_LABELS_FILE"
        fi
        exit 0
        ;;
      rm)
        nome="${3:-}"
        if [ -n "${FAKE_SECRETS_FILE:-}" ] && [ -f "$FAKE_SECRETS_FILE" ]; then
            grep -vxF "$nome" "$FAKE_SECRETS_FILE" > "$FAKE_SECRETS_FILE.tmp" 2>/dev/null
            mv "$FAKE_SECRETS_FILE.tmp" "$FAKE_SECRETS_FILE" 2>/dev/null
        fi
        if [ -n "${FAKE_SECRETS_LABELS_FILE:-}" ] && [ -f "$FAKE_SECRETS_LABELS_FILE" ]; then
            grep -v "^$nome " "$FAKE_SECRETS_LABELS_FILE" > "$FAKE_SECRETS_LABELS_FILE.tmp" 2>/dev/null
            mv "$FAKE_SECRETS_LABELS_FILE.tmp" "$FAKE_SECRETS_LABELS_FILE" 2>/dev/null
        fi
        exit 0
        ;;
      ls)
        filtro=""
        for a in "$@"; do
          case "$a" in
            label=*) filtro="${a#label=}" ;;
          esac
        done
        if [ -n "${FAKE_SECRETS_LABELS_FILE:-}" ] && [ -f "$FAKE_SECRETS_LABELS_FILE" ]; then
            awk -v f="$filtro" '$2==f {print $1}' "$FAKE_SECRETS_LABELS_FILE"
        fi
        exit 0
        ;;
    esac
    exit 0
fi

if [ "$sub" != "run" ]; then
    exit 0
fi

body="" url="" out_file="" campo_env="" prev=""
for a in "$@"; do
  case "$prev" in
    -d) body="$a" ;;
    -o) out_file="$a" ;;
    -F)
      case "$a" in
        Env=*) campo_env="${a#Env=}" ;;
      esac
      ;;
  esac
  case "$a" in http://*) url="$a" ;; esac
  prev="$a"
done

resposta="" http="200"
case "$url" in
  */api/system/status) http="200" ;;
  */api/auth) resposta='{"jwt":"FAKE-JWT"}' ;;
  */api/endpoints) resposta='[{"Id":1}]' ;;
  */api/endpoints/*/docker/swarm) resposta='{"ID":"swarm123"}' ;;
  */api/stacks/create/swarm/file)
    http="${FAKE_CREATE_HTTP:-201}"
    [ -n "${CAPTURED_ENV_FILE:-}" ] && printf '%s' "$campo_env" > "$CAPTURED_ENV_FILE"
    resposta='{"Id":1}'
    ;;
  */api/stacks)
    if [ "${FAKE_STACK_EXISTS:-false}" = true ]; then
        resposta="$(printf '[{"Id":1,"Name":"encha-panel","Env":%s}]' "${FAKE_CURRENT_ENV_JSON:-[]}")"
    else
        resposta='[]'
    fi
    ;;
  */api/stacks/*)
    http="${FAKE_PUT_HTTP:-200}"
    if [ -n "${CAPTURED_ENV_FILE:-}" ]; then
        printf '%s' "$body" | jq -c '.Env' > "$CAPTURED_ENV_FILE" 2>/dev/null
    fi
    resposta='{"Id":1}'
    ;;
esac

if [ -n "$out_file" ]; then
    printf '%s' "$resposta" > "$out_file"
    printf '%s' "$http"
else
    printf '%s' "$resposta"
fi
exit 0
EODOCKER
chmod +x "$BINDIR/docker"

# t() mínimo: os testes deste arquivo verificam COMPORTAMENTO (valores do
# env_json, secrets criados/removidos), não o texto das mensagens — i18n/
# check-parity.sh já cobre PT/EN/ES. Devolver a própria CHAVE (em vez do
# template real) também dá um jeito barato de confirmar que um caminho de
# log específico foi exercitado (grep pela chave na saída capturada).
t() { printf '%s' "$1"; }

DUMMY_STACK="$(mktemp)"
printf 'version: "3.7"\nservices: {}\n' > "$DUMMY_STACK"
trap 'rm -rf "$BINDIR" "$DUMMY_STACK"' EXIT

extrai_campo_env() {
  # $1 = arquivo com o array Env (JSON); $2 = nome da variável.
  jq -r --arg n "$2" '.[] | select(.name==$n) | .value' "$1" 2>/dev/null
}

# Roda deploy_stack_painel_via_portainer isolado (PATH falso), com as
# globais/FAKE_* já exportadas pelo chamador antes de invocar esta função.
# Devolve "RC=<código>" (stdout+stderr completos ficam em $SAIDA_STDOUT).
rodar_deploy() {
  local tag="$1"
  (
    export PATH="$BINDIR:$PATH"
    export ENCHA_CURL_IMAGE FAKE_LOG FAKE_IMAGE_LABEL FAKE_STACK_EXISTS \
           FAKE_CURRENT_ENV_JSON FAKE_CREATE_HTTP FAKE_PUT_HTTP \
           FAKE_SECRET_CREATE_FALHA FAKE_SECRETS_FILE FAKE_SECRETS_LABELS_FILE \
           FAKE_SECRETS_CONTEUDO_DIR CAPTURED_ENV_FILE \
           url_painel nome_rede_interna user_portainer pass_portainer
    # user_painel/pass_painel ficam de fora do 'export' de propósito em
    # alguns cenários (unset no chamador) — exportar uma var unset não a
    # define; se estiver setada no chamador, exporta normalmente.
    [ -n "${user_painel+x}" ] && export user_painel
    [ -n "${pass_painel+x}" ] && export pass_painel
    eval "$fn_imagem"
    eval "$fn_garantir"
    eval "$fn_limpar"
    eval "$fn_deploy"
    deploy_stack_painel_via_portainer "$DUMMY_STACK" "$tag"
    echo "RC=$?"
  ) > "$SAIDA_STDOUT" 2>&1
  tail -n1 "$SAIDA_STDOUT"
}

novo_cenario() {
  # Prepara um conjunto FRESCO de arquivos de estado (secrets/labels/log/
  # env capturado/saída) — chamar no início de cada cenário.
  FAKE_SECRETS_FILE="$(mktemp -u)"; : > "$FAKE_SECRETS_FILE"
  FAKE_SECRETS_LABELS_FILE="$(mktemp -u)"; : > "$FAKE_SECRETS_LABELS_FILE"
  FAKE_SECRETS_CONTEUDO_DIR="$(mktemp -d)"
  FAKE_LOG="$(mktemp -u)"; : > "$FAKE_LOG"
  CAPTURED_ENV_FILE="$(mktemp -u)"
  SAIDA_STDOUT="$(mktemp)"
  FAKE_CREATE_HTTP="201"
  FAKE_PUT_HTTP="200"
  FAKE_SECRET_CREATE_FALHA="false"
  unset user_painel pass_painel
}

url_painel="painel.exemplo.com"
nome_rede_interna="rede-teste"
user_portainer="svcuser"
pass_portainer="svcpass"

# ============================================================
# Cenário 0: imagem_painel_tem_label_credenciais_arquivo — "contém", não
# igualdade; "<no value>" do Go template (label ausente) nunca é true.
# ============================================================
teste_label_direto() {
  (
    export PATH="$BINDIR:$PATH"
    export FAKE_IMAGE_LABEL="$1"
    eval "$fn_imagem"
    if imagem_painel_tem_label_credenciais_arquivo "qualquer:tag"; then echo "SIM"; else echo "NAO"; fi
  )
}
[ "$(teste_label_direto "credenciais-arquivo guarda-swarm")" = "SIM" ] \
  && ok "label com 'credenciais-arquivo' entre outras palavras -> true" \
  || falha "label com 'credenciais-arquivo' entre outras palavras deveria dar true"
[ "$(teste_label_direto "guarda-swarm")" = "NAO" ] \
  && ok "label sem 'credenciais-arquivo' -> false" \
  || falha "label sem 'credenciais-arquivo' deveria dar false"
[ "$(teste_label_direto "")" = "NAO" ] \
  && ok "label vazia -> false" \
  || falha "label vazia deveria dar false"
[ "$(teste_label_direto "<no value>")" = "NAO" ] \
  && ok "'<no value>' (label ausente no Go template) -> false" \
  || falha "'<no value>' deveria dar false (imagem sem o label nenhum)"

# ============================================================
# Cenário 1: imagem SEM o label -> env_json com as senhas em texto (igual
# hoje), sem _FILE/_SECRET_NAME preenchidos — mas os secrets "bootstrap" são
# garantidos mesmo assim (pra nunca quebrar um deploy futuro que precise
# deles referenciados no compose estático).
# ============================================================
novo_cenario
FAKE_IMAGE_LABEL="guarda-swarm"
FAKE_STACK_EXISTS=false
FAKE_CURRENT_ENV_JSON="[]"
user_painel="admin"; pass_painel="SenhaForte1"

saida="$(rodar_deploy "0.3.5")"
if [ "$saida" = "RC=0" ]; then
  ok "sem label: deploy termina com sucesso"
else
  falha "sem label: esperado RC=0, obtido '$saida' — saída: $(cat "$SAIDA_STDOUT")"
fi

pp="$(extrai_campo_env "$CAPTURED_ENV_FILE" PANEL_ADMIN_PASSWORD)"
sp="$(extrai_campo_env "$CAPTURED_ENV_FILE" PORTAINER_PASSWORD)"
paf="$(extrai_campo_env "$CAPTURED_ENV_FILE" PANEL_ADMIN_PASSWORD_FILE)"
ppf="$(extrai_campo_env "$CAPTURED_ENV_FILE" PORTAINER_PASSWORD_FILE)"
pasn="$(extrai_campo_env "$CAPTURED_ENV_FILE" PANEL_ADMIN_PASSWORD_SECRET_NAME)"
if [ "$pp" = "SenhaForte1" ] && [ "$sp" = "svcpass" ]; then
  ok "sem label: PANEL_ADMIN_PASSWORD/PORTAINER_PASSWORD continuam em texto no env_json"
else
  falha "sem label: esperava senhas em texto, obtido PANEL_ADMIN_PASSWORD='$pp' PORTAINER_PASSWORD='$sp'"
fi
if [ -z "$paf" ] && [ -z "$ppf" ] && [ -z "$pasn" ]; then
  ok "sem label: nenhum *_FILE/*_SECRET_NAME preenchido"
else
  falha "sem label: esperava *_FILE/*_SECRET_NAME vazios, obtido PANEL_ADMIN_PASSWORD_FILE='$paf' PANEL_ADMIN_PASSWORD_SECRET_NAME='$pasn'"
fi
if grep -qxF "panel_admin_password_bootstrap" "$FAKE_SECRETS_FILE" && grep -qxF "portainer_password_bootstrap" "$FAKE_SECRETS_FILE"; then
  ok "sem label: os dois secrets 'bootstrap' foram garantidos mesmo assim (compose estático precisa deles existirem)"
else
  falha "sem label: 'bootstrap' não foi garantido — quebraria um deploy futuro com imagem antiga: $(cat "$FAKE_SECRETS_FILE")"
fi
if grep -qE '^panel_admin_password_[0-9]+$' "$FAKE_SECRETS_FILE"; then
  falha "sem label: criou um secret VERSIONADO à toa (não devia, imagem não suporta)"
else
  ok "sem label: nenhum secret versionado criado"
fi

# ============================================================
# Cenário 2: imagem COM o label, criação com sucesso -> env_json com as
# senhas vazias e os *_FILE certos; docker secret create chamado com o
# valor real.
# ============================================================
novo_cenario
FAKE_IMAGE_LABEL="credenciais-arquivo guarda-swarm"
FAKE_STACK_EXISTS=false
FAKE_CURRENT_ENV_JSON="[]"
user_painel="admin"; pass_painel="SenhaForte2"

saida="$(rodar_deploy "0.3.5")"
if [ "$saida" = "RC=0" ]; then
  ok "com label, sucesso: deploy termina com sucesso"
else
  falha "com label, sucesso: esperado RC=0, obtido '$saida' — saída: $(cat "$SAIDA_STDOUT")"
fi

pp="$(extrai_campo_env "$CAPTURED_ENV_FILE" PANEL_ADMIN_PASSWORD)"
sp="$(extrai_campo_env "$CAPTURED_ENV_FILE" PORTAINER_PASSWORD)"
paf="$(extrai_campo_env "$CAPTURED_ENV_FILE" PANEL_ADMIN_PASSWORD_FILE)"
ppf="$(extrai_campo_env "$CAPTURED_ENV_FILE" PORTAINER_PASSWORD_FILE)"
pasn="$(extrai_campo_env "$CAPTURED_ENV_FILE" PANEL_ADMIN_PASSWORD_SECRET_NAME)"
ppsn="$(extrai_campo_env "$CAPTURED_ENV_FILE" PORTAINER_PASSWORD_SECRET_NAME)"
if [ "$pp" = "" ] && [ "$sp" = "" ]; then
  ok "com label, sucesso: PANEL_ADMIN_PASSWORD/PORTAINER_PASSWORD esvaziados no env_json"
else
  falha "com label, sucesso: esperava senhas vazias, obtido PANEL_ADMIN_PASSWORD='$pp' PORTAINER_PASSWORD='$sp'"
fi
if [ "$paf" = "/run/secrets/panel_admin_password" ] && [ "$ppf" = "/run/secrets/portainer_password" ]; then
  ok "com label, sucesso: *_FILE apontam pro mount certo"
else
  falha "com label, sucesso: *_FILE errados: PANEL_ADMIN_PASSWORD_FILE='$paf' PORTAINER_PASSWORD_FILE='$ppf'"
fi
case "$pasn" in
  panel_admin_password_[0-9]*)
    ok "com label, sucesso: PANEL_ADMIN_PASSWORD_SECRET_NAME é um nome versionado ($pasn)"
    ;;
  *)
    falha "com label, sucesso: PANEL_ADMIN_PASSWORD_SECRET_NAME inesperado: '$pasn'"
    ;;
esac
case "$ppsn" in
  portainer_password_[0-9]*)
    ok "com label, sucesso: PORTAINER_PASSWORD_SECRET_NAME é um nome versionado ($ppsn)"
    ;;
  *)
    falha "com label, sucesso: PORTAINER_PASSWORD_SECRET_NAME inesperado: '$ppsn'"
    ;;
esac
if [ -f "$FAKE_SECRETS_CONTEUDO_DIR/$pasn" ] && [ "$(cat "$FAKE_SECRETS_CONTEUDO_DIR/$pasn")" = "SenhaForte2" ]; then
  ok "com label, sucesso: docker secret create recebeu o valor real da senha do painel"
else
  falha "com label, sucesso: conteúdo do secret do painel não é a senha real (esperado 'SenhaForte2')"
fi
if [ -f "$FAKE_SECRETS_CONTEUDO_DIR/$ppsn" ] && [ "$(cat "$FAKE_SECRETS_CONTEUDO_DIR/$ppsn")" = "svcpass" ]; then
  ok "com label, sucesso: docker secret create recebeu o valor real da senha de serviço do Portainer"
else
  falha "com label, sucesso: conteúdo do secret do Portainer não é a senha real (esperado 'svcpass')"
fi
if grep -qF "secret create $pasn --label com.encha.segredo-base=panel_admin_password -" "$FAKE_LOG"; then
  ok "com label, sucesso: docker secret create rotulado com com.encha.segredo-base=panel_admin_password"
else
  falha "com label, sucesso: chamada de docker secret create não rotulada como esperado: $(cat "$FAKE_LOG")"
fi

# ============================================================
# Cenário 3: imagem COM o label, mas docker secret create FALHA -> cai no
# comportamento de texto (as senhas continuam em texto), sem quebrar a
# instalação (RC=0), com log claro.
# ============================================================
novo_cenario
FAKE_IMAGE_LABEL="credenciais-arquivo"
FAKE_STACK_EXISTS=false
FAKE_CURRENT_ENV_JSON="[]"
FAKE_SECRET_CREATE_FALHA=true
user_painel="admin"; pass_painel="SenhaForte3"

saida="$(rodar_deploy "0.3.5")"
if [ "$saida" = "RC=0" ]; then
  ok "com label, criação falha: deploy NÃO quebra a instalação (RC=0)"
else
  falha "com label, criação falha: esperado RC=0 (nada quebra), obtido '$saida' — saída: $(cat "$SAIDA_STDOUT")"
fi
pp="$(extrai_campo_env "$CAPTURED_ENV_FILE" PANEL_ADMIN_PASSWORD)"
sp="$(extrai_campo_env "$CAPTURED_ENV_FILE" PORTAINER_PASSWORD)"
if [ "$pp" = "SenhaForte3" ] && [ "$sp" = "svcpass" ]; then
  ok "com label, criação falha: senhas continuam em texto no env_json (comportamento atual preservado)"
else
  falha "com label, criação falha: senhas deveriam continuar em texto, obtido PANEL_ADMIN_PASSWORD='$pp' PORTAINER_PASSWORD='$sp'"
fi
if grep -qF "garantir_segredos_credenciais_painel_falhou" "$SAIDA_STDOUT"; then
  ok "com label, criação falha: log claro do motivo (chave de mensagem correta)"
else
  falha "com label, criação falha: não avisou o operador: $(cat "$SAIDA_STDOUT")"
fi

# ============================================================
# Cenário 4: instalação JÁ migrada (Env atual já tem PANEL_ADMIN_PASSWORD=""
# e PANEL_ADMIN_PASSWORD_SECRET_NAME já gravado) rodando de novo SEM digitar
# senha nova (fluxo real de "Atualizar painel"/opção 97) -> não duplica
# secret à toa, nem quebra (sem_admin não dispara mesmo com texto vazio).
# PORTAINER_PASSWORD, ao contrário, sempre é conhecida (vem do disco) e por
# isso pode rotacionar normalmente — não é o que este cenário audita.
# ============================================================
novo_cenario
FAKE_IMAGE_LABEL="credenciais-arquivo"
FAKE_STACK_EXISTS=true
FAKE_CURRENT_ENV_JSON='[{"name":"PANEL_ADMIN_USER","value":"admin"},{"name":"PANEL_ADMIN_PASSWORD","value":""},{"name":"PANEL_ADMIN_PASSWORD_SECRET_NAME","value":"panel_admin_password_1111111111"},{"name":"PORTAINER_PASSWORD_SECRET_NAME","value":"portainer_password_2222222222"}]'
echo "panel_admin_password_1111111111" >> "$FAKE_SECRETS_FILE"
echo "portainer_password_2222222222" >> "$FAKE_SECRETS_FILE"
echo "panel_admin_password_1111111111 com.encha.segredo-base=panel_admin_password" >> "$FAKE_SECRETS_LABELS_FILE"
echo "portainer_password_2222222222 com.encha.segredo-base=portainer_password" >> "$FAKE_SECRETS_LABELS_FILE"
# user_painel/pass_painel de propósito NÃO setados (novo_cenario já fez unset)

saida="$(rodar_deploy "0.3.5")"
if [ "$saida" = "RC=0" ]; then
  ok "já migrado, reroda sem senha nova: não quebra (sem_admin não dispara com texto vazio + secret já gravado)"
else
  falha "já migrado, reroda sem senha nova: esperado RC=0, obtido '$saida' — saída: $(cat "$SAIDA_STDOUT")"
fi
pasn="$(extrai_campo_env "$CAPTURED_ENV_FILE" PANEL_ADMIN_PASSWORD_SECRET_NAME)"
pp="$(extrai_campo_env "$CAPTURED_ENV_FILE" PANEL_ADMIN_PASSWORD)"
if [ "$pasn" = "panel_admin_password_1111111111" ]; then
  ok "já migrado, reroda sem senha nova: PANEL_ADMIN_PASSWORD_SECRET_NAME reaproveitado, sem trocar"
else
  falha "já migrado, reroda sem senha nova: esperava reaproveitar panel_admin_password_1111111111, obtido '$pasn'"
fi
if [ "$pp" = "" ]; then
  ok "já migrado, reroda sem senha nova: PANEL_ADMIN_PASSWORD continua vazio (não regrediu pra texto)"
else
  falha "já migrado, reroda sem senha nova: PANEL_ADMIN_PASSWORD deveria continuar vazio, obtido '$pp'"
fi
if grep -qE "secret create panel_admin_password_[0-9]+ " "$FAKE_LOG"; then
  falha "já migrado, reroda sem senha nova: criou um secret NOVO à toa pro admin do painel: $(cat "$FAKE_LOG")"
else
  ok "já migrado, reroda sem senha nova: nenhum secret novo criado pro admin do painel (não duplica à toa)"
fi

# ============================================================
# Cenário 5: já migrado, mas o operador DIGITA uma senha nova nesta rodada
# (pass_painel setado) -> rotaciona pra um secret novo e, com o deploy
# confirmado, REMOVE a versão anterior (nunca o bootstrap).
# ============================================================
novo_cenario
FAKE_IMAGE_LABEL="credenciais-arquivo"
FAKE_STACK_EXISTS=true
FAKE_CURRENT_ENV_JSON='[{"name":"PANEL_ADMIN_USER","value":"admin"},{"name":"PANEL_ADMIN_PASSWORD","value":""},{"name":"PANEL_ADMIN_PASSWORD_SECRET_NAME","value":"panel_admin_password_OLDNAME"}]'
echo "panel_admin_password_OLDNAME" >> "$FAKE_SECRETS_FILE"
echo "panel_admin_password_OLDNAME com.encha.segredo-base=panel_admin_password" >> "$FAKE_SECRETS_LABELS_FILE"
user_painel="admin"; pass_painel="NovaSenha123"

saida="$(rodar_deploy "0.3.5")"
if [ "$saida" = "RC=0" ]; then
  ok "senha nova sobre instalação migrada: deploy termina com sucesso"
else
  falha "senha nova sobre instalação migrada: esperado RC=0, obtido '$saida' — saída: $(cat "$SAIDA_STDOUT")"
fi
pasn="$(extrai_campo_env "$CAPTURED_ENV_FILE" PANEL_ADMIN_PASSWORD_SECRET_NAME)"
if [ -n "$pasn" ] && [ "$pasn" != "panel_admin_password_OLDNAME" ] && [ "$pasn" != "panel_admin_password_bootstrap" ]; then
  ok "senha nova sobre instalação migrada: rotacionou pra um secret novo ($pasn)"
else
  falha "senha nova sobre instalação migrada: esperava um nome novo, obtido '$pasn'"
fi
if grep -qxF "panel_admin_password_OLDNAME" "$FAKE_SECRETS_FILE"; then
  falha "senha nova sobre instalação migrada: a versão ANTERIOR (OLDNAME) não foi removida depois do deploy confirmado: $(cat "$FAKE_SECRETS_FILE")"
else
  ok "senha nova sobre instalação migrada: a versão anterior (OLDNAME) foi removida depois do deploy confirmado"
fi
if grep -qxF "$pasn" "$FAKE_SECRETS_FILE"; then
  ok "senha nova sobre instalação migrada: a versão nova continua registrada"
else
  falha "senha nova sobre instalação migrada: a versão nova ($pasn) devia continuar em FAKE_SECRETS_FILE"
fi
if grep -qxF "panel_admin_password_bootstrap" "$FAKE_SECRETS_FILE"; then
  ok "senha nova sobre instalação migrada: o secret 'bootstrap' nunca é removido"
else
  falha "senha nova sobre instalação migrada: o secret 'bootstrap' foi removido por engano"
fi

# ============================================================
# Cenário 6: sem senha em texto E sem migração nenhuma registrada -> ainda
# é erro real (nem em escopo, nem salvo, nem por trás de um secret já
# criado) — a folga do item anterior não pode mascarar este caso.
# ============================================================
novo_cenario
FAKE_IMAGE_LABEL="credenciais-arquivo"
FAKE_STACK_EXISTS=false
FAKE_CURRENT_ENV_JSON="[]"
# user_painel/pass_painel de propósito NÃO setados

saida="$(rodar_deploy "0.3.5")"
if [ "$saida" = "RC=1" ]; then
  ok "sem admin nenhum (nem texto, nem migrado): ainda falha (comportamento existente preservado)"
else
  falha "sem admin nenhum: esperado RC=1, obtido '$saida' — saída: $(cat "$SAIDA_STDOUT")"
fi
if grep -qF "deploy_stack_painel_via_portainer_sem_admin" "$SAIDA_STDOUT"; then
  ok "sem admin nenhum: mensagem certa (chave de erro sem_admin)"
else
  falha "sem admin nenhum: não avisou com a mensagem esperada: $(cat "$SAIDA_STDOUT")"
fi

[ "$falhas" -eq 0 ] || exit 1
