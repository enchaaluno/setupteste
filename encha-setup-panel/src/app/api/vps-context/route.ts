import { NextResponse } from "next/server";
import { readSession } from "@/lib/session";
import { getVpsContext, protecaoSshInstalada } from "@/lib/vps-context";
import { resolveLocale } from "@/lib/locale";
import { unauthenticatedResponse } from "@/lib/api-error";

export async function GET() {
  const locale = await resolveLocale();
  const session = await readSession();
  if (!session) {
    return unauthenticatedResponse(locale);
  }
  const ctx = getVpsContext();
  // protecaoSshInstalada (C8, plano de segurança / A2): true quando o
  // marcador do C10 (/root/dados_vps/seguranca) existe — o painel usa isso
  // pra mostrar o aviso de fail2ban ausente (SshProtectionWarning). Campo
  // deliberadamente fora de VpsContext/getVpsContext: aquele tipo é só o que
  // vem do parsing de dados_vps, e os outros consumidores de getVpsContext
  // (terms, suporte/abrir) não precisam desse campo.
  return NextResponse.json({ ...ctx, protecaoSshInstalada: protecaoSshInstalada() });
}
