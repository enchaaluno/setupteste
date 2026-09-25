"use client";
import { useEffect, useRef, useState } from "react";
import type { UseFormReturn } from "react-hook-form";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Dialog, DialogContent, DialogHeader, DialogTitle, DialogDescription, DialogFooter } from "@/components/ui/dialog";
import { Loader2, MessageCircleWarning, RefreshCw, ArrowRightLeft } from "lucide-react";
import { useDict } from "@/lib/i18n/use-dict";
import { licensePairingText, type LicensePairingText } from "./license-pairing.i18n";

// Pareamento self-service de licença — o cliente gera a própria licença
// EnchaT de dentro do wizard, sem precisar de uma chave criada por um admin
// à mão no Console. Espelha o protocolo que web/src/components/
// AtivacaoScreen.tsx (repo ENCHAT) e ENCHAT GRÁTIS/instalador/painel.py já
// implementam — mesmos nomes de estado, mesma sequência de chamadas — só
// que ANTES do primeiro boot do app, contra as rotas /api/license/pair/*
// deste painel (nunca fala direto com o Console: ver license-pairing.ts).
//
// Fica dentro do grupo "Licença" do wizard, ao lado do campo `chave_licenca`
// manual (StackField comum, renderizado pelo install-wizard.tsx) — os dois
// convivem: este componente é o caminho principal, o campo de texto é o
// fallback pra quem já tem uma chave.

type PairingSpecUI = { targetField: string; sessionField: string; group?: string };

type Etapa =
  | { kind: "iniciando" }
  | {
      kind: "aguardando";
      pairingId: string;
      codigo: string;
      codigoExibicao?: string;
      numeroExibicao?: string;
      waLink?: string;
      waQrSvg?: string;
      expiraEm?: number;
      signupUrl?: string;
      aviso?: string;
    }
  | { kind: "aguardando_cpf"; pairingId: string; remetenteMascarado?: string }
  // Fase 2: 2 tentativas de CPF erradas destravam com email+senha do Super
  // Admin do app, em vez de queimar a sessão (ver informarCPF no Console).
  | { kind: "aguardando_credencial"; pairingId: string }
  | { kind: "escolha"; pairingId: string; licencas: LicencaOfertada[]; escolhaExpiraEm?: number }
  | { kind: "confirmado"; cliente?: string; plano?: string }
  | { kind: "recusado"; pairingId: string; motivo?: string; instalacaoAtual?: InstalacaoAtual }
  | { kind: "migrando"; pairingId: string }
  // Terceiro fator antes do rebind de verdade — abre depois que o usuário
  // confirma o aviso do Dialog ("instalação anterior está ativa há X").
  | { kind: "confirmar_migracao"; pairingId: string; instalacaoAtual?: InstalacaoAtual }
  // Fase 2.2: "celular novo, CPF que já tem cadastro" — troca o telefone
  // cadastrado pelo número já confirmado nesta sessão, via credencial.
  | { kind: "trocando_telefone"; pairingId: string }
  | { kind: "expirado" }
  | { kind: "erro"; mensagem: string }
  | { kind: "manual" }; // usuário escolheu colar uma chave existente — não pareia

type LicencaOfertada = { id: number; apelido?: string; plano?: string; vitalicia?: boolean; jaAtivadaAqui?: boolean };
type InstalacaoAtual = { ultimoCheck?: number; apelido?: string };

const POLL_INTERVALO_MS = 3000;

// Motivos "conhecidos" de mensagemRecusa (os `case` do switch, não o
// `default`) — usado só pra decidir, no catch de iniciar(), se o código de
// erro vindo do Console tem uma tradução dedicada ou se deve cair no
// fallback genérico (t.erroGenericoPareamento). Nunca traduzido: são
// códigos de protocolo, iguais nos 3 idiomas de mensagemRecusa.
const MOTIVOS_RECUSA_CONHECIDOS = new Set([
  "cpf_sem_licenca",
  "sem_licenca",
  "sem_licenca_disponivel",
  "licenca_nao_encontrada",
  "ja_ativada_em_outra_vps",
  "licenca_revogada",
  "ja_tem_conta_gratis",
  "cpf_ja_cadastrado",
  "celular_ja_cadastrado",
  "excesso_tentativas_cpf",
]);

// Motivos em que "Gerar outro código" reabriria uma sessão que vai recusar
// do mesmo jeito — mostrar o botão nesses casos é um beco sem saída sem
// explicação de por que não adianta. ja_ativada_em_outra_vps SAIU desta
// lista de propósito: agora tem uma saída própria (migrar a licença pra
// esta instalação), não o retry genérico.
const MOTIVOS_SEM_RETRY_UTIL = new Set(["licenca_revogada"]);

// Descrição legível de há quanto tempo a instalação atual deu sinal —
// alimenta o aviso antes de migrar ("ativa há 2 minutos" vs "sem sinal há
// 6 dias"), pro cliente perceber se está prestes a derrubar algo em uso.
function sinalHaQuanto(ultimoCheckS: number | undefined, t: LicensePairingText): string {
  if (!ultimoCheckS) return t.sinalNuncaVerificou;
  const segundos = Math.max(0, Math.floor(Date.now() / 1000) - ultimoCheckS);
  if (segundos < 120) return t.sinalAtivaMenos2Min;
  if (segundos < 3600) return t.sinalAtivaMinutos(Math.floor(segundos / 60));
  if (segundos < 86400) return t.sinalAtivaHoras(Math.floor(segundos / 3600));
  return t.sinalSemSinalDias(Math.floor(segundos / 86400));
}

function formatarCpf(v: string): string {
  const d = v.replace(/\D/g, "").slice(0, 11);
  if (d.length <= 3) return d;
  if (d.length <= 6) return `${d.slice(0, 3)}.${d.slice(3)}`;
  if (d.length <= 9) return `${d.slice(0, 3)}.${d.slice(3, 6)}.${d.slice(6)}`;
  return `${d.slice(0, 3)}.${d.slice(3, 6)}.${d.slice(6, 9)}-${d.slice(9)}`;
}

function qrSrc(svg: string): string {
  if (svg.startsWith("data:")) return svg;
  return `data:image/svg+xml;utf8,${encodeURIComponent(svg)}`;
}

function Countdown({ expiraEm }: { expiraEm?: number }) {
  const t = useDict(licensePairingText);
  const [agora, setAgora] = useState(() => Date.now());
  useEffect(() => {
    const id = setInterval(() => setAgora(Date.now()), 1000);
    return () => clearInterval(id);
  }, []);
  if (!expiraEm) return null;
  const restanteS = Math.max(0, Math.floor(expiraEm - agora / 1000));
  const m = Math.floor(restanteS / 60);
  const s = restanteS % 60;
  return (
    <span className="text-xs text-muted-foreground tabular-nums">
      {t.expiraEm(String(m), s.toString().padStart(2, "0"))}
    </span>
  );
}

export function LicensePairing({
  stackId,
  csrfToken,
  spec,
  form,
}: {
  stackId: string;
  csrfToken: string;
  spec: PairingSpecUI;
  form: UseFormReturn<Record<string, unknown>>;
}) {
  const t = useDict(licensePairingText);
  const [etapa, setEtapa] = useState<Etapa>({ kind: "iniciando" });
  const [cpf, setCpf] = useState("");
  const [erroCpf, setErroCpf] = useState<string | null>(null);
  const [credEmail, setCredEmail] = useState("");
  const [credSenha, setCredSenha] = useState("");
  const [erroCredencial, setErroCredencial] = useState<string | null>(null);
  const [enviandoCredencial, setEnviandoCredencial] = useState(false);
  const [confirmandoMigracao, setConfirmandoMigracao] = useState(false);
  const pollTimer = useRef<ReturnType<typeof setInterval> | null>(null);

  // Campo escondido no form pai — RHF só inclui no submit o que está
  // registrado. Vazio até o pareamento confirmar.
  form.register(spec.sessionField);

  function pararPoll() {
    if (pollTimer.current) {
      clearInterval(pollTimer.current);
      pollTimer.current = null;
    }
  }

  async function chamar(path: string, body: Record<string, unknown>): Promise<Record<string, unknown>> {
    const res = await fetch(`/api/license/${path}`, {
      method: "POST",
      headers: { "Content-Type": "application/json", "x-csrf-token": csrfToken },
      body: JSON.stringify({ stackId, ...body }),
    });
    const data = await res.json().catch(() => ({}));
    if (!res.ok) {
      // message = frase já traduzida pelo servidor (apiError); error = código
      // estável, que só serve pra lógica (fica em err.data.error). Mostrar o
      // código cru na tela ("nao_confirmou_cpf") era o bug.
      const corpo = data as { error?: string; message?: string };
      const err = new Error(corpo.message ?? corpo.error ?? `HTTP ${res.status}`) as Error & { data?: unknown };
      err.data = data;
      throw err;
    }
    return data;
  }

  // novo=true só no botão "Gerar outro código": pede ao servidor pra descartar
  // a sessão aberta em vez de retomá-la (reabrir o modal continua retomando,
  // pra não gastar as 5 tentativas/hora do Console).
  async function iniciar(novo = false) {
    setEtapa({ kind: "iniciando" });
    try {
      const d = await chamar("pair/start", novo ? { novo: true } : {});
      if (d.status === "confirmado") {
        // Retomada de um pareamento já confirmado antes (modal fechado e
        // reaberto depois da confirmação, mas antes do install consumir).
        form.setValue(spec.sessionField, d.pairingId);
        setEtapa({ kind: "confirmado" });
        iniciarPoll(d.pairingId as string); // não deveria mais mudar, mas garante consistência se o install ainda não consumiu
        return;
      }
      setEtapa({
        kind: "aguardando",
        pairingId: d.pairingId as string,
        codigo: (d.codigo as string) ?? (d.codigoExibicao as string) ?? "",
        codigoExibicao: d.codigoExibicao as string | undefined,
        numeroExibicao: d.numeroExibicao as string | undefined,
        waLink: d.waLink as string | undefined,
        waQrSvg: d.waQrSvg as string | undefined,
        expiraEm: d.expiraEm as number | undefined,
        signupUrl: d.signupUrl as string | undefined,
      });
      iniciarPoll(d.pairingId as string);
    } catch (e) {
      const data = (e as { data?: { legacy?: boolean; error?: string; message?: string } }).data;
      if (data?.legacy) {
        // Instalação anterior a este mecanismo — pareamento mudaria o
        // fingerprint de uma licença possivelmente já ativa. Cai pro
        // fallback manual sem alarde de erro.
        setEtapa({ kind: "manual" });
        return;
      }
      // Nunca mostrar o código cru (ex.: "cpf_obrigatorio",
      // "invalid_fingerprint") na tela: só usa o texto de mensagemRecusa
      // quando o código bate com um motivo conhecido, senão cai no
      // fallback genérico do dicionário.
      const codigo = data?.error ?? (e instanceof Error ? e.message : undefined);
      // "muitas_tentativas" (429 do rate limit local) traz "aguarde Ns" já
      // traduzido em message — é a única resposta cuja frase o usuário
      // precisa ver, porque a ação certa é esperar, não tentar de novo.
      const mensagem =
        codigo === "muitas_tentativas" && data?.message
          ? data.message
          : codigo && MOTIVOS_RECUSA_CONHECIDOS.has(codigo)
            ? t.mensagemRecusa(codigo)
            : t.erroGenericoPareamento;
      setEtapa({ kind: "erro", mensagem });
    }
  }

  function iniciarPoll(pairingId: string) {
    pararPoll();
    pollTimer.current = setInterval(() => poll(pairingId), POLL_INTERVALO_MS);
  }

  async function poll(pairingId: string) {
    try {
      const d = await chamar("pair/poll", { pairingId });
      switch (d.status) {
        case "confirmado":
          pararPoll();
          form.setValue(spec.sessionField, pairingId);
          setEtapa({ kind: "confirmado", cliente: d.cliente as string | undefined, plano: d.plano as string | undefined });
          return;
        case "aguardando_cpf":
          setEtapa({ kind: "aguardando_cpf", pairingId, remetenteMascarado: d.remetenteMascarado as string | undefined });
          return;
        case "escolha_pendente":
          setEtapa({
            kind: "escolha",
            pairingId,
            licencas: (d.licencas as LicencaOfertada[]) ?? [],
            escolhaExpiraEm: d.escolhaExpiraEm as number | undefined,
          });
          return;
        case "recusado":
          pararPoll();
          setEtapa({
            kind: "recusado",
            pairingId,
            motivo: d.motivo as string | undefined,
            instalacaoAtual: d.instalacaoAtual as InstalacaoAtual | undefined,
          });
          return;
        case "expirado":
          pararPoll();
          setEtapa({ kind: "expirado" });
          return;
        case "consumido":
          // Já foi usado por um install anterior desta mesma sessão de
          // pareamento — não deveria acontecer no meio de um wizard aberto,
          // mas se acontecer só para de perguntar, sem alarmar.
          pararPoll();
          return;
        default:
          // "aguardando" — continua polling; mantém a etapa atual (não
          // reseta o card pra não piscar a cada 3s).
          setEtapa((prev) => (prev.kind === "aguardando" ? { ...prev, aviso: d.aviso as string | undefined } : prev));
      }
    } catch {
      // Erro de transporte no poll não derruba a sessão — tenta de novo no
      // próximo tick, igual ao app Go faz.
    }
  }

  async function confirmarCpf() {
    if (etapa.kind !== "aguardando_cpf") return;
    const digitos = cpf.replace(/\D/g, "");
    if (digitos.length !== 11) {
      setErroCpf(t.erroCpfObrigatorio);
      return;
    }
    setErroCpf(null);
    const pairingId = etapa.pairingId;
    try {
      await chamar("pair/cpf", { pairingId, cpf: digitos });
      // sucesso: o PRÓXIMO poll é quem resolve (confirmado/recusado) — este
      // endpoint só aciona a etapa, mesmo padrão do app Go.
    } catch (e) {
      const data = (e as Error & { data?: { error?: string; tentativas_restantes?: number } }).data;
      if (data?.error === "aguardando_credencial") {
        // 2ª tentativa errada — Fase 2: destrava com email+senha em vez de
        // exigir suporte. Não é um erro de transporte nem de digitação.
        setEtapa({ kind: "aguardando_credencial", pairingId });
        return;
      }
      if (data?.error === "sessao_expirada") {
        // Console não conhece mais esta sessão (expirou / foi apagada):
        // retentar o CPF é inútil — para de pollar e oferece novo código.
        pararPoll();
        setEtapa({ kind: "expirado" });
        return;
      }
      if (data?.error === "cpf_nao_confere") {
        setErroCpf(
          typeof data.tentativas_restantes === "number"
            ? t.cpfNaoConfereComTentativas(data.tentativas_restantes)
            : t.cpfNaoConfere
        );
        return;
      }
      setErroCpf(e instanceof Error ? e.message : t.erroConfirmarCpf);
    }
  }

  async function confirmarCredencial() {
    if (etapa.kind !== "aguardando_credencial") return;
    if (!credEmail || !credSenha) {
      setErroCredencial(t.erroCredencialObrigatoria);
      return;
    }
    setErroCredencial(null);
    setEnviandoCredencial(true);
    try {
      await chamar("pair/credencial", { pairingId: etapa.pairingId, email: credEmail, senha: credSenha });
      // sucesso: o poll (que continua rodando em segundo plano) resolve
      // "confirmado" no próximo tick — mesmo padrão de confirmarCpf/escolher.
    } catch (e) {
      setErroCredencial(e instanceof Error ? e.message : t.erroConfirmarCredencial);
    } finally {
      setEnviandoCredencial(false);
    }
  }

  async function escolher(licenseId: number) {
    if (etapa.kind !== "escolha") return;
    try {
      await chamar("pair/choose", { pairingId: etapa.pairingId, licenseId });
    } catch {
      // poll seguinte revela o resultado
    }
  }

  async function migrar() {
    if (etapa.kind !== "confirmar_migracao") return;
    if (!credEmail || !credSenha) {
      setErroCredencial(t.erroCredencialObrigatoria);
      return;
    }
    setErroCredencial(null);
    setEnviandoCredencial(true);
    const pairingId = etapa.pairingId;
    try {
      const d = await chamar("pair/migrar", { pairingId, email: credEmail, senha: credSenha });
      setEtapa({ kind: "migrando", pairingId });
      if (d.sessao_reutilizavel) {
        // Mesma sessão, agora com a licença já vinculada a esta VPS — deixa
        // a etapa "migrando" (spinner) até o próximo poll resolver
        // "confirmado" sozinho; não precisa de estado intermediário novo.
        iniciarPoll(pairingId);
      } else {
        // Sessão anterior foi consumida (caminho de múltiplas licenças) — a
        // licença já foi migrada, mas esta sessão específica não serve
        // mais; abre uma nova, que resolve de primeira (fingerprint já bate).
        iniciar();
      }
    } catch (e) {
      // Fica na MESMA etapa (confirmar_migracao) — credenciais erradas são
      // pra tentar de novo aqui, não pra voltar pro aviso do Dialog.
      setErroCredencial(e instanceof Error ? e.message : t.erroMigrarLicenca);
    } finally {
      setEnviandoCredencial(false);
    }
  }

  async function confirmarTrocaTelefone() {
    if (etapa.kind !== "trocando_telefone") return;
    if (!credEmail || !credSenha) {
      setErroCredencial(t.erroCredencialObrigatoria);
      return;
    }
    setErroCredencial(null);
    setEnviandoCredencial(true);
    const pairingId = etapa.pairingId;
    try {
      await chamar("pair/trocar-telefone", { pairingId, email: credEmail, senha: credSenha });
      // sucesso: mesma sessão, agora com o telefone trocado e a licença já
      // resolvida — o próximo poll confirma sozinho (mesmo padrão de migrar).
      iniciarPoll(pairingId);
    } catch (e) {
      setErroCredencial(e instanceof Error ? e.message : t.erroTrocarNumero);
    } finally {
      setEnviandoCredencial(false);
    }
  }

  useEffect(() => {
    iniciar();
    return () => pararPoll();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  if (etapa.kind === "manual") return null; // campo chave_licenca comum já cobre este caso

  if (etapa.kind === "iniciando") {
    return (
      <div className="flex items-center gap-2 text-sm text-muted-foreground py-2">
        <Loader2 className="h-4 w-4 animate-spin" />
        {t.preparando}
      </div>
    );
  }

  if (etapa.kind === "erro") {
    return (
      <div className="space-y-2 rounded-md border border-destructive/40 bg-destructive/10 p-3">
        <p className="text-sm text-destructive">{etapa.mensagem}</p>
        <Button type="button" variant="outline" size="sm" onClick={() => iniciar()}>
          <RefreshCw className="h-3.5 w-3.5 mr-1.5" />
          {t.tentarDeNovo}
        </Button>
        <p className="text-xs text-muted-foreground">
          {t.informeChaveExistente}
        </p>
      </div>
    );
  }

  if (etapa.kind === "migrando") {
    return (
      <div className="flex items-center gap-2 text-sm text-muted-foreground py-2">
        <Loader2 className="h-4 w-4 animate-spin" />
        {t.migrandoLicenca}
      </div>
    );
  }

  if (etapa.kind === "trocando_telefone") {
    return (
      <div className="space-y-2">
        <p className="text-sm text-muted-foreground">
          {t.trocarTelefoneDesc}
        </p>
        <Label htmlFor="pairing-troca-email">{t.emailLabel}</Label>
        <Input
          id="pairing-troca-email"
          type="email"
          placeholder={t.emailPlaceholder}
          value={credEmail}
          onChange={(e) => setCredEmail(e.target.value)}
        />
        <Label htmlFor="pairing-troca-senha">{t.senhaLabel}</Label>
        <Input
          id="pairing-troca-senha"
          type="password"
          value={credSenha}
          onChange={(e) => setCredSenha(e.target.value)}
        />
        {erroCredencial && <p className="text-xs text-destructive">{erroCredencial}</p>}
        <Button type="button" size="sm" onClick={confirmarTrocaTelefone} disabled={enviandoCredencial}>
          {enviandoCredencial && <Loader2 className="h-3.5 w-3.5 mr-1.5 animate-spin" />}
          {t.trocarNumeroBotao}
        </Button>
      </div>
    );
  }

  if (etapa.kind === "confirmar_migracao") {
    return (
      <div className="space-y-2">
        <p className="text-sm text-muted-foreground">
          {t.migrarDesc}
        </p>
        <p className="text-xs text-muted-foreground">
          {t.migrarPrimeiraVez}
        </p>
        {etapa.instalacaoAtual && (
          <p className="text-xs text-muted-foreground">
            {t.instalacaoAnteriorPrefixo}{sinalHaQuanto(etapa.instalacaoAtual.ultimoCheck, t)}
            {etapa.instalacaoAtual.apelido ? ` ("${etapa.instalacaoAtual.apelido}")` : ""}.
          </p>
        )}
        <Label htmlFor="pairing-migrar-email">{t.emailLabel}</Label>
        <Input
          id="pairing-migrar-email"
          type="email"
          placeholder={t.emailPlaceholder}
          value={credEmail}
          onChange={(e) => setCredEmail(e.target.value)}
        />
        <Label htmlFor="pairing-migrar-senha">{t.senhaLabel}</Label>
        <Input
          id="pairing-migrar-senha"
          type="password"
          value={credSenha}
          onChange={(e) => setCredSenha(e.target.value)}
        />
        {erroCredencial && <p className="text-xs text-destructive">{erroCredencial}</p>}
        <Button type="button" size="sm" onClick={migrar} disabled={enviandoCredencial}>
          {enviandoCredencial && <Loader2 className="h-3.5 w-3.5 mr-1.5 animate-spin" />}
          {t.migrarLicencaBotao}
        </Button>
      </div>
    );
  }

  if (etapa.kind === "recusado" || etapa.kind === "expirado") {
    const ehOutraVps = etapa.kind === "recusado" && etapa.motivo === "ja_ativada_em_outra_vps";
    const ehCpfJaCadastrado = etapa.kind === "recusado" && etapa.motivo === "cpf_ja_cadastrado";
    const semRetryUtil =
      etapa.kind === "recusado" && MOTIVOS_SEM_RETRY_UTIL.has(etapa.motivo ?? "") && !ehOutraVps && !ehCpfJaCadastrado;
    return (
      <div className="space-y-2 rounded-md border border-amber-500/40 bg-amber-500/10 p-3">
        <p className="text-sm text-amber-600 dark:text-amber-400">
          {etapa.kind === "expirado" ? t.expiradoMensagem : t.mensagemRecusa(etapa.motivo)}
        </p>
        {ehOutraVps ? (
          <Button type="button" variant="outline" size="sm" onClick={() => setConfirmandoMigracao(true)}>
            <ArrowRightLeft className="h-3.5 w-3.5 mr-1.5" />
            {t.migrarLicencaEstaMinha}
          </Button>
        ) : ehCpfJaCadastrado ? (
          <Button
            type="button"
            variant="outline"
            size="sm"
            onClick={() => setEtapa({ kind: "trocando_telefone", pairingId: etapa.pairingId })}
          >
            <ArrowRightLeft className="h-3.5 w-3.5 mr-1.5" />
            {t.trocarCpfMeu}
          </Button>
        ) : (
          !semRetryUtil && (
            <Button type="button" variant="outline" size="sm" onClick={() => iniciar(true)}>
              <RefreshCw className="h-3.5 w-3.5 mr-1.5" />
              {t.gerarOutroCodigo}
            </Button>
          )
        )}
        <p className="text-xs text-muted-foreground">{t.informeChaveExistente}</p>

        {ehOutraVps && (
          <Dialog open={confirmandoMigracao} onOpenChange={setConfirmandoMigracao}>
            <DialogContent>
              <DialogHeader>
                <DialogTitle>{t.migrarDialogTitle}</DialogTitle>
                <DialogDescription>
                  {t.migrarDialogDescPrefix}
                  <strong>{sinalHaQuanto(etapa.instalacaoAtual?.ultimoCheck, t)}</strong>
                  {etapa.instalacaoAtual?.apelido ? ` ("${etapa.instalacaoAtual.apelido}")` : ""}
                  {t.migrarDialogDescSuffix}
                </DialogDescription>
              </DialogHeader>
              <DialogFooter>
                <Button type="button" variant="outline" size="sm" onClick={() => setConfirmandoMigracao(false)}>
                  {t.cancelar}
                </Button>
                <Button
                  type="button"
                  size="sm"
                  onClick={() => {
                    if (etapa.kind !== "recusado") return;
                    setConfirmandoMigracao(false);
                    setErroCredencial(null);
                    // Terceiro fator: só o aviso do Dialog não autoriza o
                    // rebind — precisa da senha do dono, próxima tela.
                    setEtapa({ kind: "confirmar_migracao", pairingId: etapa.pairingId, instalacaoAtual: etapa.instalacaoAtual });
                  }}
                >
                  <ArrowRightLeft className="h-3.5 w-3.5 mr-1.5" />
                  {t.continuar}
                </Button>
              </DialogFooter>
            </DialogContent>
          </Dialog>
        )}
      </div>
    );
  }

  if (etapa.kind === "confirmado") {
    return (
      <div className="rounded-md border border-emerald-500/40 bg-emerald-500/10 p-3 text-sm text-emerald-600 dark:text-emerald-400">
        {t.licencaPareada(etapa.cliente, etapa.plano)}
      </div>
    );
  }

  if (etapa.kind === "aguardando_cpf") {
    return (
      <div className="space-y-2">
        <p className="text-sm text-muted-foreground">
          {t.recebemosCodigo(etapa.remetenteMascarado)}
        </p>
        <Label htmlFor="pairing-cpf">{t.cpfTitularLabel}</Label>
        <Input
          id="pairing-cpf"
          placeholder={t.cpfPlaceholder}
          value={formatarCpf(cpf)}
          onChange={(e) => setCpf(e.target.value)}
        />
        {erroCpf && <p className="text-xs text-destructive">{erroCpf}</p>}
        <Button type="button" size="sm" onClick={confirmarCpf}>{t.continuar}</Button>
      </div>
    );
  }

  if (etapa.kind === "aguardando_credencial") {
    return (
      <div className="space-y-2">
        <p className="text-sm text-muted-foreground">
          {t.naoDeuCpfDesc}
        </p>
        <Label htmlFor="pairing-cred-email">{t.emailLabel}</Label>
        <Input
          id="pairing-cred-email"
          type="email"
          placeholder={t.emailPlaceholder}
          value={credEmail}
          onChange={(e) => setCredEmail(e.target.value)}
        />
        <Label htmlFor="pairing-cred-senha">{t.senhaLabel}</Label>
        <Input
          id="pairing-cred-senha"
          type="password"
          value={credSenha}
          onChange={(e) => setCredSenha(e.target.value)}
        />
        {erroCredencial && <p className="text-xs text-destructive">{erroCredencial}</p>}
        <Button type="button" size="sm" onClick={confirmarCredencial} disabled={enviandoCredencial}>
          {enviandoCredencial && <Loader2 className="h-3.5 w-3.5 mr-1.5 animate-spin" />}
          {t.entrarBotao}
        </Button>
      </div>
    );
  }

  if (etapa.kind === "escolha") {
    return (
      <div className="space-y-2">
        <div className="flex items-center justify-between">
          <p className="text-sm text-muted-foreground">{t.encontramosVariasLicencas}</p>
          <Countdown expiraEm={etapa.escolhaExpiraEm} />
        </div>
        <div className="space-y-1.5">
          {etapa.licencas.map((l) => (
            <button
              key={l.id}
              type="button"
              onClick={() => escolher(l.id)}
              className="w-full text-left rounded-md border border-input p-2.5 hover:bg-accent transition-colors"
            >
              <div className="font-medium text-sm">{l.apelido ?? t.licencaFallback(l.id)}</div>
              <div className="text-xs text-muted-foreground">
                {l.plano}
                {l.vitalicia ? t.vitaliciaSufixo : ""}
                {l.jaAtivadaAqui ? t.jaAtivadaAquiSufixo : ""}
              </div>
            </button>
          ))}
        </div>
      </div>
    );
  }

  // aguardando
  return (
    <div className="space-y-3">
      <div className="flex items-start justify-between gap-2">
        <div>
          <p className="text-sm">
            {t.mandarPrefixo}<span className="font-mono font-semibold">{etapa.codigoExibicao ?? etapa.codigo}</span>{t.mandarSufixo(etapa.numeroExibicao)}
          </p>
          {etapa.aviso && (
            <p className="flex items-center gap-1.5 text-xs text-amber-600 dark:text-amber-400 mt-1">
              <MessageCircleWarning className="h-3.5 w-3.5" />
              {t.mensagemAviso(etapa.aviso)}
            </p>
          )}
        </div>
        <Countdown expiraEm={etapa.expiraEm} />
      </div>
      {etapa.waLink && (
        <a href={etapa.waLink} target="_blank" rel="noopener noreferrer">
          <Button type="button" size="sm" className="w-full">{t.abrirWhatsappBotao}</Button>
        </a>
      )}
      {etapa.waQrSvg && (
        // eslint-disable-next-line @next/next/no-img-element
        <img src={qrSrc(etapa.waQrSvg)} alt={t.qrAltText} className="mx-auto h-40 w-40" />
      )}
      <div className="flex items-center justify-between text-xs">
        {etapa.signupUrl && (
          <a href={etapa.signupUrl} target="_blank" rel="noopener noreferrer" className="text-primary hover:underline">
            {t.aindaNaoTenhoConta}
          </a>
        )}
        <button type="button" onClick={() => iniciar(true)} className="text-muted-foreground hover:text-foreground ml-auto">
          {t.gerarOutroCodigo}
        </button>
      </div>
    </div>
  );
}
