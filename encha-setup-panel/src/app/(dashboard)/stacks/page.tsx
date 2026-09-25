"use client";
import { useEffect, useState } from "react";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Badge } from "@/components/ui/badge";
import { EmptyState } from "@/components/ui/empty-state";
import { ListChecks, Inbox, Info } from "lucide-react";
import { useLocale } from "@/components/locale-provider";
import { toBcp47 } from "@/lib/locale-shared";
import { useDict } from "@/lib/i18n/use-dict";
import { stacksPageText } from "./page.i18n";
import { PrimeiroAcessoCard } from "@/components/primeiro-acesso-card";

type InstalledStack = { id: number; name: string; createdAt: number; external?: boolean };

export default function StacksPage() {
  const { locale } = useLocale();
  const t = useDict(stacksPageText);
  const [stacks, setStacks] = useState<InstalledStack[]>([]);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    (async () => {
      try {
        const r = await fetch("/api/stacks");
        if (r.ok) {
          const d = await r.json();
          setStacks(d.installed ?? []);
        }
      } finally {
        setLoading(false);
      }
    })();
  }, []);

  return (
    <div className="space-y-6">
      <header className="space-y-2">
        <h1 className="text-2xl font-semibold flex items-center gap-2">
          <ListChecks className="h-6 w-6 text-primary" />
          {t.title}
        </h1>
        <p className="text-sm text-muted-foreground">
          {t.subtitle}
        </p>
        <div className="flex items-start gap-2 p-3 rounded-md bg-info-soft text-info-foreground text-sm">
          <Info className="h-4 w-4 shrink-0 mt-0.5" />
          <span>
            {t.editHint}
          </span>
        </div>
      </header>

      {loading ? (
        <div className="text-muted-foreground">{t.loading}</div>
      ) : stacks.length === 0 ? (
        <EmptyState
          icon={Inbox}
          title={t.emptyTitle}
          description={t.emptyDescription}
        />
      ) : (
        <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
          {stacks.map((s) => (
            <Card key={s.id} variant="glass">
              <CardHeader>
                <CardTitle className="flex items-center justify-between gap-2">
                  <span className="truncate">{s.name}</span>
                  <div className="flex gap-1.5 shrink-0">
                    {s.external && <Badge variant="neutral">{t.external}</Badge>}
                    <Badge variant="success">{t.active}</Badge>
                  </div>
                </CardTitle>
              </CardHeader>
              <CardContent>
                <div className="text-xs text-muted-foreground">
                  {t.installedAt(new Date(s.createdAt * 1000).toLocaleString(toBcp47(locale)))}
                </div>
                {s.name === "enchat" && <PrimeiroAcessoCard stackId="enchat" />}
              </CardContent>
            </Card>
          ))}
        </div>
      )}
    </div>
  );
}
