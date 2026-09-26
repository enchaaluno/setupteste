#!/usr/bin/env bash
# Prova que main.sh (TERMS_VERSION), legal/TERMOS-DE-USO.md (cabeçalho +
# cláusula 25.1) e legal/termos-de-uso.html (badge + cláusula 25.1) nunca
# divergem. Publicar Termos novos sem sincronizar os três lugares deixa o
# instalador cobrando aceite de uma versão que o texto real já não é.
set -euo pipefail
RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
falhas=0

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; falhas=$((falhas + 1)); }

versao_main() {
    grep -E '^TERMS_VERSION="' "$RAIZ/main.sh" | head -1 | sed -E 's/^TERMS_VERSION="([0-9]+)"/\1/'
}
versao_md_cabecalho() {
    grep -E '^\*\*Versão [0-9]+ — vigente desde' "$RAIZ/legal/TERMOS-DE-USO.md" | head -1 \
        | sed -E 's/^\*\*Versão ([0-9]+) .*/\1/'
}
versao_md_clausula() {
    grep -E '25\.1\. Estes Termos correspondem à \*\*versão [0-9]+\*\*' "$RAIZ/legal/TERMOS-DE-USO.md" \
        | sed -E 's/.*versão ([0-9]+)\*\*.*/\1/'
}
versao_html_badge() {
    grep -E 'version-badge">Versão [0-9]+' "$RAIZ/legal/termos-de-uso.html" \
        | sed -E 's/.*Versão ([0-9]+) ·.*/\1/'
}
versao_html_clausula() {
    grep -E '25\.1\. Estes Termos correspondem à <strong>versão [0-9]+</strong>' "$RAIZ/legal/termos-de-uso.html" \
        | sed -E 's/.*versão ([0-9]+)<\/strong>.*/\1/'
}

vm="$(versao_main)"
vmc="$(versao_md_cabecalho)"
vmcl="$(versao_md_clausula)"
vhb="$(versao_html_badge)"
vhcl="$(versao_html_clausula)"

[ -n "$vm" ] && pass "main.sh tem TERMS_VERSION" || fail "main.sh sem TERMS_VERSION"
[ -n "$vmc" ] && pass ".md tem cabeçalho de versão" || fail ".md sem cabeçalho de versão"
[ -n "$vmcl" ] && pass ".md tem cláusula 25.1" || fail ".md sem cláusula 25.1"
[ -n "$vhb" ] && pass ".html tem badge de versão" || fail ".html sem badge de versão"
[ -n "$vhcl" ] && pass ".html tem cláusula 25.1" || fail ".html sem cláusula 25.1"

if [ "$vm" = "$vmc" ] && [ "$vm" = "$vmcl" ] && [ "$vm" = "$vhb" ] && [ "$vm" = "$vhcl" ]; then
    pass "main.sh ($vm) = .md cabeçalho ($vmc) = .md 25.1 ($vmcl) = .html badge ($vhb) = .html 25.1 ($vhcl)"
else
    fail "divergência: main.sh=$vm .md_cab=$vmc .md_251=$vmcl .html_badge=$vhb .html_251=$vhcl"
fi

# A data "vigente desde" também precisa bater entre .md e .html (main.sh não
# guarda data, só versão — TERMS_URL aponta para o site que tem a data real).
data_md() {
    grep -E '^\*\*Versão [0-9]+ — vigente desde' "$RAIZ/legal/TERMOS-DE-USO.md" | head -1 \
        | sed -E 's/.*vigente desde ([^.]+)\.\*\*/\1/'
}
data_html() {
    grep -E 'version-badge">Versão [0-9]+' "$RAIZ/legal/termos-de-uso.html" \
        | sed -E 's/.*vigente desde ([^<]+)<\/span>.*/\1/'
}
dmd="$(data_md)"; dht="$(data_html)"
[ "$dmd" = "$dht" ] && pass "data 'vigente desde' igual em .md e .html ($dmd)" \
    || fail "data diverge: .md='$dmd' .html='$dht'"

echo "--- $falhas falha(s) ---"
[ "$falhas" -eq 0 ]
