"use client";
import { useState } from "react";
import { AlertTriangle, Copy, Check } from "lucide-react";
import { useDict } from "@/lib/i18n/use-dict";
import { sshProtectionWarningText } from "./ssh-protection-warning.i18n";

// Comando exposto pelo C10 (secondary.sh) — menu interativo e chamada
// direta, ver plano de segurança "A2 — fail2ban". Se o nome mudar no C10,
// mudar só aqui.
export const COMANDO_PROTEGER_SSH = "bash /root/SetupEnchaAI proteger-ssh";

// Extraída para ser testável sem montar o componente (mutação do auditor:
// "inverte a condição"). `null` = /api/vps-context ainda não respondeu —
// não mostra nada nesse instante, pra não piscar o aviso numa VPS já
// protegida enquanto a resposta não chega.
export function deveExibirAvisoProtecaoSsh(protecaoInstalada: boolean | null): boolean {
  return protecaoInstalada === false;
}

// Lê protecaoSshInstalada da resposta de GET /api/vps-context. Campo
// ausente ou de outro tipo → true ("protegido", sem aviso): painel e rota
// saem no mesmo build do Next, então ausência só acontece com rota
// mockada/resposta inesperada — e o aviso é informativo, não bloqueia nada.
export function protecaoSshDaResposta(d: unknown): boolean {
  const v = (d as { protecaoSshInstalada?: unknown } | null)?.protecaoSshInstalada;
  return typeof v === "boolean" ? v : true;
}

export function SshProtectionWarning({ protecaoInstalada }: { protecaoInstalada: boolean | null }) {
  const t = useDict(sshProtectionWarningText);
  const [copiado, setCopiado] = useState(false);

  if (!deveExibirAvisoProtecaoSsh(protecaoInstalada)) return null;

  // "Copiado!" só depois que a cópia deu certo: fora de contexto seguro
  // (painel aberto por http://IP) navigator.clipboard não existe, e o
  // writeText pode rejeitar (permissão negada). Nesses casos o comando
  // continua visível para copiar à mão — o botão só não mente.
  function copiar() {
    const clip = typeof navigator !== "undefined" ? navigator.clipboard : undefined;
    if (!clip) return;
    clip.writeText(COMANDO_PROTEGER_SSH).then(
      () => {
        setCopiado(true);
        setTimeout(() => setCopiado(false), 1500);
      },
      () => {},
    );
  }

  return (
    <div className="flex items-start gap-2 p-3 rounded-md bg-warning-soft text-warning-foreground text-sm">
      <AlertTriangle className="h-4 w-4 shrink-0 mt-0.5" />
      <div className="flex-1 space-y-1.5">
        <p>{t.message}</p>
        <div className="flex items-center gap-2 flex-wrap">
          <code className="text-xs font-mono bg-warm-900/10 dark:bg-warm-50/10 rounded px-2 py-1">
            {COMANDO_PROTEGER_SSH}
          </code>
          <button
            onClick={copiar}
            className="inline-flex items-center gap-1 text-xs font-medium hover:underline"
          >
            {copiado ? <Check className="h-3.5 w-3.5" /> : <Copy className="h-3.5 w-3.5" />}
            {copiado ? t.copied : t.copy}
          </button>
        </div>
      </div>
    </div>
  );
}
