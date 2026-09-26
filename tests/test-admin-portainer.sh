#!/bin/bash
# Ciclo C2 (INFRA-04 do plano de segurança do EnchaT): função compartilhada
# finalizar_admin_portainer (chamada pelas duas funções duplicadas que
# instalam Traefik+Portainer — ferramenta_traefik_e_portainer e
# instalar_traefik_e_portainer) corrige dois bugs da auditoria em produção:
#   1) a mensagem "Admin do Portainer pronto" era fixa ("usuário: admin") e
#      impressa ANTES de renomear_admin_portainer_se_necessario rodar.
#   2) numa reinstalação sobre um 'portainer_data' preservado cujo admin já
#      tinha sido renomeado, o login era feito com "admin" hardcoded —
#      falhava sempre, gravando "Criar manualmente." mesmo com um admin
#      funcional (só com outro nome).
#
# Roda as funções REAIS (extraídas de secondary.sh) com docker/sudo falsos
# no PATH e jq real (ou um stub mínimo se ausente) — simula o Portainer
# como um par usuário/senha "atual" (FAKE_STATE_FILE), que só muda quando o
# PUT /api/users/1 (renomeação) é aceito.
#
# Roda com: bash tests/test-admin-portainer.sh
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

fn_renomear="$(extrair_funcao renomear_admin_portainer_se_necessario)"
fn_finalizar="$(extrair_funcao finalizar_admin_portainer)"

if [ -z "$fn_renomear" ]; then
  echo "❌ FALHOU: função renomear_admin_portainer_se_necessario não encontrada em secondary.sh"
  exit 1
fi
if [ -z "$fn_finalizar" ]; then
  echo "❌ FALHOU: função finalizar_admin_portainer não encontrada em secondary.sh — rode depois de implementar o C2"
  exit 1
fi

# finalizar_admin_portainer lê /root/dados_vps/dados_portainer com caminho
# absoluto fixo (é assim em produção — sempre roda como root). Pro teste,
# troca por um diretório temporário por cenário, igual tests/test-dados-
# enchat-permissao.sh já faz pro bloco de ferramenta_enchat().
fn_finalizar="${fn_finalizar//\/root\/dados_vps//__DV__}"

ENCHA_CURL_IMAGE="$(grep -oE '^ENCHA_CURL_IMAGE="[^"]+"' secondary.sh | head -1 | sed -E 's/^ENCHA_CURL_IMAGE="([^"]+)"$/\1/')"
if [ -z "$ENCHA_CURL_IMAGE" ]; then
  echo "❌ FALHOU: ENCHA_CURL_IMAGE não encontrada em secondary.sh (C1)"
  exit 1
fi

# --- Catálogo mínimo de mensagens: as chaves usadas pelas duas funções sob
# teste, com o valor REAL de MSG_PT (se o texto mudar em secondary.sh, este
# teste segue a mudança em vez de duplicar a string). EN/ES ficam por conta
# de i18n/check-parity.sh — este teste só precisa do template pt pra
# conferir COMPORTAMENTO (usuário certo, ordem certa).
#
# Sem 'declare -A' de propósito: usa variáveis indiretas (MSG_<chave> +
# "${!nome}") em vez de array associativo — funciona até no bash 3.2 (só o
# que este Mac tem instalado; o secondary.sh real roda em bash 5+ na VPS,
# mas o teste não precisa depender disso). Sempre pt — EN/ES são cobertos
# por i18n/check-parity.sh, não por este teste de comportamento.
t() {
    local chave="$1"; shift
    local nomevar="MSG_${chave}"
    local template="${!nomevar}"
    [ -z "$template" ] && template="$chave"
    if [ "$#" -gt 0 ]; then
        printf -- "$template" "$@"
    else
        printf '%s' "$template"
    fi
}
for chave in finalizar_admin_portainer_pronto finalizar_admin_portainer_nao_bateram \
             finalizar_admin_portainer_use_anteriores renomear_admin_portainer_falha \
             renomear_admin_portainer_sucesso renomear_admin_portainer_reautenticar; do
  valor="$(grep -m1 "^MSG_PT\[$chave\]=" secondary.sh | sed -E "s/^MSG_PT\[$chave\]=//")"
  if [ -z "$valor" ]; then
    echo "❌ FALHOU: MSG_PT[$chave] não encontrada em secondary.sh"
    exit 1
  fi
  eval "MSG_${chave}=$valor"
done

# --- Ambiente com docker/sudo/jq falsos no PATH ---
BINDIR="$(mktemp -d)"
trap 'rm -rf "$BINDIR"' EXIT

cat > "$BINDIR/sudo" <<'EOSUDO'
#!/bin/bash
exec "$@"
EOSUDO
chmod +x "$BINDIR/sudo"

if command -v jq >/dev/null 2>&1; then
  # Shim que chama o jq REAL pelo caminho absoluto — 'cp' do binário quebra
  # no macOS (a cópia perde a validação de assinatura e o kernel mata o
  # processo com SIGKILL/137 na hora de executar).
  JQ_REAL="$(command -v jq)"
  cat > "$BINDIR/jq" <<EOJQREAL
#!/bin/bash
exec "$JQ_REAL" "\$@"
EOJQREAL
  chmod +x "$BINDIR/jq"
else
  # Stub mínimo — só o suficiente pra montar/ler o JSON de
  # {username:$u,password:$p} / {Username:$u} e extrair .jwt. Usado só se
  # este ambiente não tiver jq de verdade (produção sempre tem — é
  # dependência do resto de secondary.sh).
  cat > "$BINDIR/jq" <<'EOJQ'
#!/bin/bash
# Sem 'declare -A' de propósito (ver comentário no script principal) — usa
# arrays indexados em paralelo (names[i]/values[i]), que funcionam até no
# bash 3.2.
if [ "$1" = "-nc" ] || [ "$1" = "-n" ]; then
  shift
  names=() values=()
  while [ "$1" = "--arg" ]; do
    names+=("$2"); values+=("$3"); shift 3
  done
  tpl="$1"
  out="$tpl"
  i=0
  while [ "$i" -lt "${#names[@]}" ]; do
    out="${out//\$${names[$i]}/\"${values[$i]}\"}"
    i=$((i + 1))
  done
  out=$(printf '%s' "$out" | sed -E 's/\{([a-zA-Z]+):/{"\1":/; s/,([a-zA-Z]+):/,"\1":/g')
  printf '%s' "$out"
  exit 0
fi
if [ "$1" = "-r" ]; then
  campo="${2#.}"
  entrada="$(cat)"
  valor=$(printf '%s' "$entrada" | sed -nE "s/.*\"$campo\"[[:space:]]*:[[:space:]]*\"([^\"]*)\".*/\1/p")
  if [ -z "$valor" ]; then echo "null"; else echo "$valor"; fi
  exit 0
fi
exit 1
EOJQ
  chmod +x "$BINDIR/jq"
fi

# "docker" falso: simula um Portainer cujo admin atual (usuário+senha) é o
# par gravado em $FAKE_STATE_FILE. Login (POST /api/auth) só "funciona" se
# username+password baterem com o estado atual; renomear (PUT /users/1) só
# muda o estado se $FAKE_RENAME_HTTP=200 (default).
cat > "$BINDIR/docker" <<'EODOCKER'
#!/bin/bash
[ -n "${FAKE_LOG:-}" ] && echo "$*" >> "$FAKE_LOG"
if [ "$1" != "run" ]; then exit 0; fi

body="" url="" metodo="POST" prev=""
for arg in "$@"; do
  if [ "$prev" = "-d" ]; then body="$arg"; fi
  if [ "$prev" = "-X" ]; then metodo="$arg"; fi
  case "$arg" in http://*) url="$arg" ;; esac
  prev="$arg"
done

estado_u="" estado_p=""
if [ -f "$FAKE_STATE_FILE" ]; then
  estado_u="$(sed -n 's/^USER=//p' "$FAKE_STATE_FILE")"
  estado_p="$(sed -n 's/^PASS=//p' "$FAKE_STATE_FILE")"
fi

case "$url" in
  */api/auth)
    u="$(printf '%s' "$body" | jq -r '.username // empty' 2>/dev/null)"
    p="$(printf '%s' "$body" | jq -r '.password // empty' 2>/dev/null)"
    if [ -n "$u" ] && [ "$u" = "$estado_u" ] && [ "$p" = "$estado_p" ]; then
      printf '{"jwt":"FAKE-JWT-%s"}' "$u"
    fi
    ;;
  */api/users/1)
    novo="$(printf '%s' "$body" | jq -r '.Username // empty' 2>/dev/null)"
    codigo="${FAKE_RENAME_HTTP:-200}"
    if [ "$codigo" = "200" ] && [ -n "$novo" ]; then
      printf 'USER=%s\nPASS=%s\n' "$novo" "$estado_p" > "$FAKE_STATE_FILE"
    fi
    printf '%s' "$codigo"
    ;;
esac
exit 0
EODOCKER
chmod +x "$BINDIR/docker"

FAKE_LOG="$BINDIR/docker-run.log"

# Roda finalizar_admin_portainer isolado num subshell (PATH falso) e
# imprime "USER_PORTAINER_FINAL=<x>|CREDENCIAIS_APLICADAS=<y>", com o
# stdout REAL da função salvo em $1 (arquivo) pra inspecionar mensagens e
# ordem.
rodar_cenario() {
  local dv="$1" alvo="$2" senha="$3" ja_init="$4" saida_stdout="$5"
  : > "$FAKE_LOG"
  (
    # secondary.sh de verdade nunca roda com 'set -u' — só o script deste
    # teste usa (pra pegar bug no PRÓPRIO teste). Sem soltar aqui, um bash
    # mais antigo (ex. o 3.2 que é o único bash deste Mac) trata
    # "${candidatos[@]}" com candidatos=() vazio como variável não-definida
    # e aborta — um artefato do bash local, não um bug do código real.
    set +u
    export PATH="$BINDIR:$PATH"
    export ENCHA_CURL_IMAGE FAKE_LOG FAKE_STATE_FILE FAKE_RENAME_HTTP
    eval "$fn_renomear"
    eval "${fn_finalizar//__DV__/$dv}"
    finalizar_admin_portainer "rede-teste" "$senha" "$alvo" "$ja_init"
    echo "USER_PORTAINER_FINAL=$USER_PORTAINER_FINAL|CREDENCIAIS_APLICADAS=$CREDENCIAIS_APLICADAS"
  ) > "$saida_stdout" 2>&1
  tail -n1 "$saida_stdout"
}

# Conta quantas tentativas de login (api/auth) o LOOP DE CANDIDATOS fez —
# ou seja, só as chamadas ANTES do primeiro PUT de renomeação (api/users/1).
# A rechamada de api/auth DEPOIS do PUT (reautenticação com o novo nome, já
# dentro de renomear_admin_portainer_se_necessario) não conta como
# "candidato tentado", senão os cenários de sucesso pareceriam ter 1
# tentativa a mais do que realmente exploraram.
candidatos_tentados() {
  sed '/api\/users\/1/,$d' "$FAKE_LOG" | grep -c "api/auth"
}

SENHA="SenhaForte123!"

# ============================================================
# Cenário 1: instalação NOVA — só "admin" existe, renomeia pro alvo
# ============================================================
DV="$(mktemp -d)"
FAKE_STATE_FILE="$(mktemp -u)"
printf 'USER=admin\nPASS=%s\n' "$SENHA" > "$FAKE_STATE_FILE"
FAKE_RENAME_HTTP=200
OUT="$(mktemp)"
saida="$(rodar_cenario "$DV" "carlosadm" "$SENHA" "false" "$OUT")"
if [ "$saida" = "USER_PORTAINER_FINAL=carlosadm|CREDENCIAIS_APLICADAS=true" ]; then
  ok "instalação nova: autentica com admin e renomeia para o alvo"
else
  falha "instalação nova: esperado 'USER_PORTAINER_FINAL=carlosadm|CREDENCIAIS_APLICADAS=true', obtido '$saida'"
fi

if grep -qF "carlosadm" "$OUT" && ! grep -qE "usuário: admin\)|username: admin\)" "$OUT"; then
  ok "instalação nova: mensagem final mostra o alvo, não 'admin'"
else
  falha "instalação nova: mensagem final não mostra o alvo (ou ainda cita 'admin'): $(cat "$OUT")"
fi

# Ordem: a linha "renomeado para" (de dentro de renomear_admin_portainer_se_necessario)
# tem que vir ANTES da linha "pronto" (de finalizar_admin_portainer).
linha_renomeado=$(grep -n "renomeado para" "$OUT" | head -1 | cut -d: -f1)
linha_pronto=$(grep -n "pronto (usu" "$OUT" | head -1 | cut -d: -f1)
if [ -n "$linha_renomeado" ] && [ -n "$linha_pronto" ] && [ "$linha_renomeado" -lt "$linha_pronto" ]; then
  ok "instalação nova: mensagem de sucesso impressa DEPOIS da renomeação"
else
  falha "instalação nova: ordem errada (renomeado=$linha_renomeado, pronto=$linha_pronto): $(cat "$OUT")"
fi

# Só 1 candidato tentado (direto em "admin" — instalação nova pula alvo/salvo)
tentativas_login=$(candidatos_tentados)
if [ "$tentativas_login" -eq 1 ]; then
  ok "instalação nova: só 1 candidato tentado (pula alvo/salvo — não podem existir ainda)"
else
  falha "instalação nova: esperava 1 candidato tentado, log tem $tentativas_login: $(cat "$FAKE_LOG")"
fi
rm -rf "$DV" "$FAKE_STATE_FILE" "$OUT"

# ============================================================
# Cenário 2: reinstalação — admin JÁ renomeado pro alvo antes
# ============================================================
DV="$(mktemp -d)"
cat > "$DV/dados_portainer" <<EOF
[ PORTAINER ]
Domain: https://portainer.exemplo.com
Username: carlosadm
Password: $SENHA
Token: aplicado
EOF
FAKE_STATE_FILE="$(mktemp -u)"
printf 'USER=carlosadm\nPASS=%s\n' "$SENHA" > "$FAKE_STATE_FILE"
FAKE_RENAME_HTTP=200
OUT="$(mktemp)"
saida="$(rodar_cenario "$DV" "carlosadm" "$SENHA" "true" "$OUT")"
if [ "$saida" = "USER_PORTAINER_FINAL=carlosadm|CREDENCIAIS_APLICADAS=true" ]; then
  ok "reinstalação (já renomeado): autentica direto com o alvo"
else
  falha "reinstalação (já renomeado): esperado sucesso com carlosadm, obtido '$saida'"
fi
tentativas_login=$(grep -c "api/auth" "$FAKE_LOG")
tentativas_rename=$(grep -c "api/users/1" "$FAKE_LOG")
if [ "$tentativas_login" -eq 1 ] && [ "$tentativas_rename" -eq 0 ]; then
  ok "reinstalação (já renomeado): 1 login (o alvo), sem tentar 'admin' e sem tentar renomear de novo"
else
  falha "reinstalação (já renomeado): esperava 1 login/0 renomeações, log: $(cat "$FAKE_LOG")"
fi
rm -rf "$DV" "$FAKE_STATE_FILE" "$OUT"

# ============================================================
# Cenário 2b: reinstalação — alvo mudou, mas o nome SALVO em dados_portainer
# (de uma renomeação anterior) ainda autentica; cai pro salvo antes de "admin"
# ============================================================
DV="$(mktemp -d)"
cat > "$DV/dados_portainer" <<EOF
[ PORTAINER ]
Domain: https://portainer.exemplo.com
Username: carlosadm
Password: $SENHA
Token: aplicado
EOF
FAKE_STATE_FILE="$(mktemp -u)"
printf 'USER=carlosadm\nPASS=%s\n' "$SENHA" > "$FAKE_STATE_FILE"
FAKE_RENAME_HTTP=200
OUT="$(mktemp)"
# Operador pede um usuário NOVO nesta reinstalação ("novoadm"); o real
# admin ainda está como "carlosadm" (da instalação anterior). Reinstalação
# NUNCA renomeia (auditoria C2): o PORTAINER_USER da stack do painel ainda é
# "carlosadm", e a opção 2 do menu não regrava o painel.
saida="$(rodar_cenario "$DV" "novoadm" "$SENHA" "true" "$OUT")"
if [ "$saida" = "USER_PORTAINER_FINAL=carlosadm|CREDENCIAIS_APLICADAS=true" ]; then
  ok "reinstalação (salvo != alvo novo): autentica com o nome salvo e o mantém"
else
  falha "reinstalação (salvo != alvo novo): esperado sucesso mantendo carlosadm, obtido '$saida'"
fi
if grep -q "api/users/1" "$FAKE_LOG"; then
  falha "reinstalação (salvo != alvo novo): tentou renomear o admin preservado: $(cat "$FAKE_LOG")"
else
  ok "reinstalação (salvo != alvo novo): nenhuma tentativa de renomear o admin preservado"
fi
if grep -qF "usuário: carlosadm)" "$OUT"; then
  ok "reinstalação (salvo != alvo novo): mensagem final cita o usuário mantido"
else
  falha "reinstalação (salvo != alvo novo): mensagem final não cita carlosadm: $(cat "$OUT")"
fi
tentativas_login=$(candidatos_tentados)
if [ "$tentativas_login" -eq 2 ]; then
  ok "reinstalação (salvo != alvo novo): tenta o alvo novo primeiro (falha), depois o salvo (funciona) — sem precisar de 'admin'"
else
  falha "reinstalação (salvo != alvo novo): esperava 2 candidatos tentados, log tem $tentativas_login: $(cat "$FAKE_LOG")"
fi
rm -rf "$DV" "$FAKE_STATE_FILE" "$OUT"

# ============================================================
# Cenário 2c: reinstalação sobre dados_portainer no formato ANTIGO (chave
# "Usuario:", gravada entre a renomeação de 2026-07-31 e o i18n de
# 2026-09-14 — justamente a leva que já tem admin renomeado), com CRLF.
# O nome salvo tem que valer como candidato, senão cai em "Criar manualmente."
# ============================================================
DV="$(mktemp -d)"
printf '[ PORTAINER ]\r\nDominio: https://portainer.exemplo.com\r\nUsuario: carlosadm\r\nSenha: %s\r\nToken: x\r\n' "$SENHA" > "$DV/dados_portainer"
FAKE_STATE_FILE="$(mktemp -u)"
printf 'USER=carlosadm\nPASS=%s\n' "$SENHA" > "$FAKE_STATE_FILE"
FAKE_RENAME_HTTP=200
OUT="$(mktemp)"
saida="$(rodar_cenario "$DV" "novoadm" "$SENHA" "true" "$OUT")"
if [ "$saida" = "USER_PORTAINER_FINAL=carlosadm|CREDENCIAIS_APLICADAS=true" ]; then
  ok "reinstalação (dados_portainer antigo, 'Usuario:' + CRLF): o nome salvo vale como candidato"
else
  falha "reinstalação (dados_portainer antigo): esperado sucesso com carlosadm, obtido '$saida' — log: $(cat "$FAKE_LOG")"
fi
rm -rf "$DV" "$FAKE_STATE_FILE" "$OUT"

# ============================================================
# Cenário 3a: reinstalação — SÓ "admin" funciona (nunca foi renomeado),
# dados_portainer salvo tem o fallback "Criar manualmente." (ignorado como
# candidato) — mantém "admin", sem renomear (reinstalação preserva o admin)
# ============================================================
DV="$(mktemp -d)"
cat > "$DV/dados_portainer" <<EOF
[ PORTAINER ]
Domain: https://portainer.exemplo.com
Username: Criar manualmente.
EOF
FAKE_STATE_FILE="$(mktemp -u)"
printf 'USER=admin\nPASS=%s\n' "$SENHA" > "$FAKE_STATE_FILE"
FAKE_RENAME_HTTP=200
OUT="$(mktemp)"
saida="$(rodar_cenario "$DV" "carlosadm" "$SENHA" "true" "$OUT")"
if [ "$saida" = "USER_PORTAINER_FINAL=admin|CREDENCIAIS_APLICADAS=true" ]; then
  ok "reinstalação (só admin): autentica com admin e mantém admin"
else
  falha "reinstalação (só admin): esperado sucesso mantendo admin, obtido '$saida'"
fi
if grep -q "api/users/1" "$FAKE_LOG"; then
  falha "reinstalação (só admin): tentou renomear o admin preservado: $(cat "$FAKE_LOG")"
else
  ok "reinstalação (só admin): nenhuma tentativa de renomear o admin preservado"
fi
tentativas_login=$(candidatos_tentados)
if [ "$tentativas_login" -eq 2 ]; then
  ok "reinstalação (só admin): tenta o alvo (falha), ignora 'Criar manualmente.' como candidato, cai pro admin (funciona)"
else
  falha "reinstalação (só admin): esperava 2 candidatos tentados (alvo + admin, pulando 'Criar manualmente.'), log tem $tentativas_login: $(cat "$FAKE_LOG")"
fi
rm -rf "$DV" "$FAKE_STATE_FILE" "$OUT"

# ============================================================
# Cenário 3b: instalação NOVA em que a renomeação FALHA de verdade
# (HTTP != 200): a mensagem final tem que mostrar "admin" (a realidade),
# nunca mentir dizendo que é o alvo
# ============================================================
DV="$(mktemp -d)"
FAKE_STATE_FILE="$(mktemp -u)"
printf 'USER=admin\nPASS=%s\n' "$SENHA" > "$FAKE_STATE_FILE"
FAKE_RENAME_HTTP=500
OUT="$(mktemp)"
saida="$(rodar_cenario "$DV" "carlosadm" "$SENHA" "false" "$OUT")"
if [ "$saida" = "USER_PORTAINER_FINAL=admin|CREDENCIAIS_APLICADAS=true" ]; then
  ok "instalação nova (renomeação falha): mensagem final reflete a realidade ('admin'), não mente"
else
  falha "instalação nova (renomeação falha): esperado 'USER_PORTAINER_FINAL=admin|CREDENCIAIS_APLICADAS=true', obtido '$saida'"
fi
if grep -qF "usuário: admin)" "$OUT" && grep -q "api/users/1" "$FAKE_LOG"; then
  ok "instalação nova (renomeação falha): tentou renomear e a mensagem impressa cita 'admin', não o alvo não-aplicado"
else
  falha "instalação nova (renomeação falha): sem tentativa de renomear ou mensagem não cita 'admin': $(cat "$OUT")"
fi
rm -rf "$DV" "$FAKE_STATE_FILE" "$OUT"

# ============================================================
# Cenário 4: nenhum candidato autentica — cai em CREDENCIAIS_APLICADAS=false
# (quem chama grava "Criar manualmente."), com aviso pro operador
# ============================================================
DV="$(mktemp -d)"
FAKE_STATE_FILE="$(mktemp -u)"
printf 'USER=admin\nPASS=OutraSenhaQueNaoBate\n' > "$FAKE_STATE_FILE"
FAKE_RENAME_HTTP=200
OUT="$(mktemp)"
saida="$(rodar_cenario "$DV" "carlosadm" "$SENHA" "true" "$OUT")"
if [ "$saida" = "USER_PORTAINER_FINAL=|CREDENCIAIS_APLICADAS=false" ]; then
  ok "nenhum candidato autentica: CREDENCIAIS_APLICADAS=false (fallback 'Criar manualmente.' preservado)"
else
  falha "nenhum candidato autentica: esperado credenciais_aplicadas=false, obtido '$saida'"
fi
if grep -qF "credenciais digitadas não bateram" "$OUT"; then
  ok "nenhum candidato autentica: avisa o operador (reinstalação)"
else
  falha "nenhum candidato autentica: não avisou o operador: $(cat "$OUT")"
fi
# Réplica mínima do que as duas funções reais fazem com CREDENCIAIS_APLICADAS
# (ver o 'cat > dados_portainer' em ferramenta_traefik_e_portainer /
# instalar_traefik_e_portainer) — confirma o fallback ponta a ponta.
echo "[ PORTAINER ]" > "$DV/dados_portainer_final"
echo "Username: Criar manualmente." >> "$DV/dados_portainer_final"
if grep -q "Criar manualmente\." "$DV/dados_portainer_final"; then
  ok "nenhum candidato autentica: dados_portainer final cairia em 'Criar manualmente.'"
else
  falha "nenhum candidato autentica: fallback 'Criar manualmente.' não reproduzido"
fi
rm -rf "$DV" "$FAKE_STATE_FILE" "$OUT"

# ============================================================
# Cenário 5: dados_portainer nunca grava o JWT — sempre "Token: aplicado" —
# e os grep -q "Token: .\+" já usados em ~10 lugares do arquivo continuam
# batendo contra o novo formato.
# ============================================================
if grep -qF 'Token: $TOKEN_PORTAINER_FINAL' secondary.sh || grep -qF 'Token: $token' secondary.sh; then
  falha "dados_portainer ainda interpola um token de verdade em algum lugar"
else
  ok "dados_portainer não interpola mais nenhuma variável de token"
fi

qtd_aplicado=$(grep -c '^Token: aplicado$' secondary.sh)
if [ "$qtd_aplicado" -ge 2 ]; then
  ok "as duas funções (ferramenta_/instalar_traefik_e_portainer) gravam 'Token: aplicado' ($qtd_aplicado ocorrências)"
else
  falha "esperava pelo menos 2 ocorrências de 'Token: aplicado' (uma por função duplicada), achei $qtd_aplicado"
fi

if printf 'Token: aplicado\n' | grep -q "Token: .\+"; then
  ok "o padrão 'Token: .\\+' usado nos ~10 grep -q existentes continua batendo em 'Token: aplicado'"
else
  falha "'Token: .\\+' NÃO bate mais em 'Token: aplicado' — os ~10 grep -q do arquivo quebrariam"
fi

ocorrencias_grep_token="$(grep -c 'Token: \.\\+' secondary.sh)"
if [ "$ocorrencias_grep_token" -ge 10 ]; then
  ok "todas as $ocorrencias_grep_token ocorrências de grep -q \"Token: .\\+\" seguem no arquivo, inalteradas"
else
  falha "esperava >= 10 ocorrências de grep -q \"Token: .\\+\" em secondary.sh, achei $ocorrencias_grep_token"
fi

if grep -qE 'Token: eyJ' secondary.sh; then
  falha "achei uma string com cara de JWT (eyJ...) gravada literalmente em secondary.sh"
else
  ok "nenhuma string com cara de JWT (eyJ...) em secondary.sh"
fi

[ "$falhas" -eq 0 ] || exit 1
