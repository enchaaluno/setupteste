#!/bin/bash
# Espelha main e a tag da release em carlosmaximiliano-cloud/instalador-encha
# (release.yml, passo "Push no espelho"). Best-effort: o passo do workflow tem
# continue-on-error, mas ESTE script sai com 1 quando algo falha, pra a falha
# aparecer no resumo da run — antes o 403 (token sem escrita) ficava enterrado
# num passo "verde" e o espelho ficou parado em v0.2.5 sem ninguém notar.
#
# Uso: push-mirror.sh <version>
# Env: MIRROR_TOKEN (secret MIRROR_PUSH_TOKEN). MIRROR_URL só para teste local.
#      Sem token: aviso e exit 0 (mirror é opcional).
set -uo pipefail

VERSION="${1:?uso: push-mirror.sh <version>}"

if [ -z "${MIRROR_TOKEN:-}" ] && [ -z "${MIRROR_URL:-}" ]; then
    echo "::warning::MIRROR_PUSH_TOKEN não configurado — pulando push no espelho."
    exit 0
fi

URL="${MIRROR_URL:-https://x-access-token:${MIRROR_TOKEN}@github.com/carlosmaximiliano-cloud/instalador-encha.git}"

falha() {
    echo "::warning::Espelho instalador-encha NÃO atualizado: $1"
    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
        echo "⚠️ **Espelho instalador-encha não atualizado** — $1 (release v$VERSION publicada normalmente no setupteste)." >> "$GITHUB_STEP_SUMMARY"
    fi
    exit 1
}

git remote remove mirror 2>/dev/null || true
git remote add mirror "$URL"

# Sem este fetch não existe refs/remotes/mirror/main e um --force-with-lease
# sem valor esperado é recusado como "stale info". Falhar aqui é o sinal de
# credencial sem acesso (403) ou repositório errado.
if ! git fetch --quiet mirror main; then
    falha "não consegui ler o espelho (token sem acesso ou expirado? renove o secret MIRROR_PUSH_TOKEN)"
fi
esperado="$(git rev-parse mirror/main)"

# Main e tag são tentadas de forma independente: a falha de uma não pode
# impedir a outra (antes, o 'set -e' fazia o push da tag nem rodar).
erros=""
git push --quiet mirror "HEAD:refs/heads/main" --force-with-lease="main:${esperado}" || erros="$erros main"
git push --quiet mirror "refs/tags/v${VERSION}:refs/tags/v${VERSION}" || erros="$erros tag"

if [ -n "$erros" ]; then
    falha "push recusado para:${erros}"
fi
echo "OK: espelho atualizado (main e v$VERSION)."
