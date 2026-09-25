"use client";
import { useEffect, useState } from "react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { useDict } from "@/lib/i18n/use-dict";
import { installWizardText } from "@/components/wizard/install-wizard.i18n";

// Link de primeiro acesso (?setup=) de uma stack já instalada, na página de
// stacks — o mesmo bloco do card de sucesso do wizard, mas que sobrevive ao
// fechamento dele. Some sozinho quando o app já tem administrador (a rota
// devolve jaCriado) ou quando o painel não tem o material do link.
export function PrimeiroAcessoCard({ stackId }: { stackId: string }) {
  const t = useDict(installWizardText);
  const [setupUrl, setSetupUrl] = useState<string | null>(null);

  useEffect(() => {
    let cancelado = false;
    (async () => {
      try {
        const r = await fetch(`/api/stacks/${encodeURIComponent(stackId)}/primeiro-acesso`, { cache: "no-store" });
        if (!r.ok) return;
        const d = (await r.json()) as { setupUrl?: string };
        if (!cancelado && d.setupUrl) setSetupUrl(d.setupUrl);
      } catch {
        // Sem rede/painel fora: o card simplesmente não aparece.
      }
    })();
    return () => {
      cancelado = true;
    };
  }, [stackId]);

  if (!setupUrl) return null;

  return (
    <div className="mt-3 space-y-2 rounded-md border border-primary/40 bg-primary/10 p-3">
      <Label className="text-xs font-semibold">{t.linkPrimeiroAcesso}</Label>
      <div className="flex gap-2">
        <Input readOnly value={setupUrl} className="font-mono text-xs" onFocus={(e) => e.currentTarget.select()} />
        <Button type="button" variant="outline" onClick={() => navigator.clipboard.writeText(setupUrl)}>
          {t.copiar}
        </Button>
        <a href={setupUrl} target="_blank" rel="noopener noreferrer">
          <Button type="button">{t.abrirPrimeiroAcesso}</Button>
        </a>
      </div>
      <p className="text-xs text-muted-foreground">{t.linkPrimeiroAcessoNota}</p>
    </div>
  );
}
