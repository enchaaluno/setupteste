#!/bin/bash
# Auditoria S12 (plano de segurança do EnchaT): o caminho legado do EnchaT
# em secondary.sh (ferramenta_enchat) monta o enchat.yaml num heredoc. Três
# garantias que nenhum outro teste cobria — um nome de variável errado ali
# (ex.: "$pinfy_sesion_key") vira string vazia em silêncio e o Pinfy grava
# a sessão do WhatsApp em claro, ou nunca consegue logar no Postgres:
#   - enchat_app recebe PINFY_DB_PASSWORD (o app cria o papel "pinfy" com ela);
#   - enchat_pinfy conecta como "pinfy" com a MESMA senha, nunca como "enchat";
#   - enchat_pinfy recebe SESSION_KEY, e só ele.
# Roda o heredoc REAL (extraído de secondary.sh) com valores marcados.
# Roda com: bash tests/test-enchat-yaml-pinfy.sh
set -u
cd "$(dirname "$0")/.."

heredoc="$(awk '
  /^ferramenta_enchat\(\)\{/ { f = 1 }
  f && /^  cat > enchat.yaml <<EOL$/ { p = 1 }
  p { print }
  p && /^EOL$/ { exit }
' secondary.sh)"

if [ -z "$heredoc" ]; then
  echo "❌ FALHOU: heredoc do enchat.yaml não encontrado em ferramenta_enchat()"
  exit 1
fi

DIR="$(mktemp -d)"
trap 'rm -rf "$DIR"' EXIT
(
  set +u
  cd "$DIR"
  pinfy_db_password="SENHA-PAPEL-PINFY-DE-TESTE"
  pinfy_session_key="CHAVE-SESSAO-DE-TESTE"
  postgres_password="PG-DE-TESTE"
  eval "$heredoc"
)

bloco() {
  awk -v nome="  $1:" '
    $0 == nome { p = 1; next }
    p && /^  [A-Za-z_][A-Za-z0-9_]*:$/ { exit }
    p { print }
  ' "$DIR/enchat.yaml"
}

falhas=0
falha() { echo "❌ FALHOU: $1"; falhas=$((falhas + 1)); }

app="$(bloco enchat_app)"
pinfy="$(bloco enchat_pinfy)"
[ -n "$app" ] || falha "serviço enchat_app não encontrado no YAML"
[ -n "$pinfy" ] || falha "serviço enchat_pinfy não encontrado no YAML"

printf '%s\n' "$app" | grep -q 'PINFY_DB_PASSWORD: "SENHA-PAPEL-PINFY-DE-TESTE"' ||
  falha "enchat_app sem PINFY_DB_PASSWORD com a senha gerada"
printf '%s\n' "$app" | grep -q 'CHAVE-SESSAO-DE-TESTE' &&
  falha "enchat_app recebendo a chave da sessão (é só do Pinfy)"
printf '%s\n' "$pinfy" | grep -q 'DATABASE_URL: "postgresql://pinfy:SENHA-PAPEL-PINFY-DE-TESTE@enchat_postgres:5432/enchat?schema=pinfy' ||
  falha "enchat_pinfy não conecta como pinfy com a PINFY_DB_PASSWORD"
printf '%s\n' "$pinfy" | grep -q 'postgresql://enchat:' &&
  falha "enchat_pinfy ainda conecta como o superusuário enchat"
printf '%s\n' "$pinfy" | grep -q 'SESSION_KEY: "CHAVE-SESSAO-DE-TESTE"' ||
  falha "enchat_pinfy sem SESSION_KEY com a chave gerada"

if [ "$falhas" -eq 0 ]; then
  echo "✅ enchat.yaml: papel pinfy e SESSION_KEY nos serviços certos"
else
  exit 1
fi
