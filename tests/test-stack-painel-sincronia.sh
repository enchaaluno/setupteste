#!/bin/bash
# Ciclo C9 (M3 do plano de segurança do EnchaT): o docker-stack.yaml do
# painel tem DUAS cópias — a rastreada (encha-setup-panel/docker-stack.yaml,
# fonte da verdade, é o que o Portainer edita/mostra em produção) e o
# heredoc FALLBACK dentro de ferramenta_encha_panel() em secondary.sh (usado
# só quando o repo do painel não está presente no host). O cabeçalho do
# .yaml já pede "mantenha em sincronia" há tempos, mas não existia nenhum
# teste que garantisse isso — é exatamente esse buraco que abriu espaço pro
# heredoc ficar sem o bloco `resources:` que o .yaml já tinha.
#
# Este teste normaliza os dois (remove comentários de linha inteira e linhas
# vazias — o cabeçalho do .yaml é só comentário, o heredoc nem tem cabeçalho)
# e compara texto igual, ponta a ponta a partir de `services:`.
#
# Roda com: bash tests/test-stack-painel-sincronia.sh
set -u
cd "$(dirname "$0")/.." || exit 1
falhas=0
falha() { echo "❌ FALHOU: $1"; falhas=$((falhas + 1)); }
ok() { echo "✅ $1"; }

YAML="encha-setup-panel/docker-stack.yaml"
if [ ! -f "$YAML" ]; then
  echo "❌ FALHOU: $YAML não encontrado"
  exit 1
fi

# Extrai o heredoc entre `cat > "$stack_template" <<'TEMPLATE'` e a linha
# `TEMPLATE` sozinha, dentro de ferramenta_encha_panel() (secondary.sh) —
# sem incluir os marcadores.
heredoc="$(awk '
  /cat > "\$stack_template" <<.TEMPLATE.$/ { f = 1; next }
  f && /^TEMPLATE$/ { exit }
  f { print }
' secondary.sh)"

if [ -z "$heredoc" ]; then
  echo "❌ FALHOU: heredoc do docker-stack.yaml (fallback) não encontrado em ferramenta_encha_panel() — rode depois de implementar o C9, ou confira se o marcador <<'TEMPLATE' mudou"
  exit 1
fi

HEREDOC_FILE="$(mktemp)"
printf '%s\n' "$heredoc" > "$HEREDOC_FILE"

# Normaliza: tira comentários de linha inteira e linhas em branco. Nenhum
# dos dois arquivos usa comentário inline (só de linha inteira), então isto
# não corre o risco de apagar dado de verdade.
normalizar() {
  grep -vE '^[[:space:]]*#' "$1" | grep -vE '^[[:space:]]*$'
}

YAML_NORM="$(mktemp)"
HEREDOC_NORM="$(mktemp)"
trap 'rm -f "$HEREDOC_FILE" "$YAML_NORM" "$HEREDOC_NORM"' EXIT
normalizar "$YAML" > "$YAML_NORM"
normalizar "$HEREDOC_FILE" > "$HEREDOC_NORM"

if diff -u "$YAML_NORM" "$HEREDOC_NORM" > /tmp/diff-stack-painel-sincronia.$$; then
  ok "docker-stack.yaml (rastreado) e o heredoc fallback de secondary.sh são equivalentes (ignorando comentários/linhas vazias)"
else
  falha "docker-stack.yaml e o heredoc fallback DIVERGEM — mantenha os dois em sincronia (ver cabeçalho do .yaml). Diff:
$(cat /tmp/diff-stack-painel-sincronia.$$)"
fi
rm -f "/tmp/diff-stack-painel-sincronia.$$"

# Garantias específicas do C9 nos dois lados — se o diff acima já passou
# isto é redundante, mas torna o motivo do teste explícito (e continua
# pegando o caso em que os dois arquivos divergiram *juntos*, da mesma
# forma, o que o diff sozinho não detectaria).
for arquivo in "$YAML" "$HEREDOC_FILE"; do
  nome_exibicao="$arquivo"
  [ "$arquivo" = "$HEREDOC_FILE" ] && nome_exibicao="heredoc (secondary.sh)"

  if grep -qE '^\s*- source: panel_admin_password$' "$arquivo" \
     && grep -qE '^\s*target: panel_admin_password$' "$arquivo" \
     && grep -qE '^\s*mode: 0400$' "$arquivo"; then
    ok "$nome_exibicao: monta o secret panel_admin_password (target + mode 0400)"
  else
    falha "$nome_exibicao: não monta panel_admin_password como esperado"
  fi

  # Cada mount de senha precisa de uid/gid 1001 (USER nextjs do Dockerfile)
  # JUNTO do mode 0400 — sem uid o Swarm monta root:root 0400 e o painel não
  # lê a própria senha (medido no Portainer 2.45.1 real, auditoria C9). Olha
  # o BLOCO do mount (source + as 4 linhas seguintes), não o arquivo inteiro:
  # um "mode: 0400"/"uid:" solto em outro lugar não pode satisfazer isto.
  for base in panel_admin_password portainer_password; do
    bloco="$(awk -v b="$base" '
      $0 ~ "^[[:space:]]*- source: " b "$" { f = 1; n = 0; next }
      f && n < 4 { print; n++ }
      f && n >= 4 { exit }
    ' "$arquivo")"
    if printf '%s\n' "$bloco" | grep -qE '^[[:space:]]*uid: "1001"$' \
       && printf '%s\n' "$bloco" | grep -qE '^[[:space:]]*gid: "1001"$' \
       && printf '%s\n' "$bloco" | grep -qE '^[[:space:]]*mode: 0400$'; then
      ok "$nome_exibicao: mount de $base legível pelo painel (uid/gid 1001 + mode 0400)"
    else
      falha "$nome_exibicao: mount de $base sem uid/gid \"1001\" + mode 0400 — o painel (USER nextjs, uid 1001) não consegue ler o arquivo"
    fi
  done

  if grep -qE '^\s*- source: portainer_password$' "$arquivo" \
     && grep -qE '^\s*target: portainer_password$' "$arquivo"; then
    ok "$nome_exibicao: monta o secret portainer_password"
  else
    falha "$nome_exibicao: não monta portainer_password como esperado"
  fi

  if grep -qF 'PANEL_ADMIN_PASSWORD_FILE=${PANEL_ADMIN_PASSWORD_FILE}' "$arquivo" \
     && grep -qF 'PORTAINER_PASSWORD_FILE=${PORTAINER_PASSWORD_FILE}' "$arquivo"; then
    ok "$nome_exibicao: environment expõe os dois *_FILE"
  else
    falha "$nome_exibicao: environment não expõe PANEL_ADMIN_PASSWORD_FILE/PORTAINER_PASSWORD_FILE"
  fi

  if grep -qF 'name: ${PANEL_ADMIN_PASSWORD_SECRET_NAME:-panel_admin_password_bootstrap}' "$arquivo" \
     && grep -qF 'name: ${PORTAINER_PASSWORD_SECRET_NAME:-portainer_password_bootstrap}' "$arquivo"; then
    ok "$nome_exibicao: secrets top-level externos com default pro '_bootstrap' (nunca falta um nome pra resolver)"
  else
    falha "$nome_exibicao: secrets top-level sem o default '_bootstrap' esperado"
  fi
done

[ "$falhas" -eq 0 ] || exit 1
