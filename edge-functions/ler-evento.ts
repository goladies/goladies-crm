// Go Ladies — Edge Function "ler-evento"
// Lê a página pública de um evento no Sympla e devolve os dados e a arte para
// preencher a Divulgação do CRM. Não salva nada e não usa IA (sem custo).
// Só aceita endereços do Sympla e só responde para a equipe (eh_staff).
//
// COMO IMPLANTAR (primeira vez):
// 1. Supabase (go-ladies-crm) → Edge Functions → Create a new function
// 2. Nome da função: ler-evento
// 3. Cole todo este arquivo no editor e clique em Deploy
// 4. Confirme que "Verify JWT" está ligado (é o padrão)
// Não precisa de chave nova.

const ORIGENS_LIBERADAS = ["https://crm.goladies.com.br"];

function montarCors(req: Request) {
  const origem = req.headers.get("origin") ?? "";
  return {
    "Access-Control-Allow-Origin": ORIGENS_LIBERADAS.includes(origem) ? origem : ORIGENS_LIBERADAS[0],
    "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Vary": "Origin",
  };
}

const PAGINA_MAX = 3 * 1024 * 1024;
const IMAGEM_MAX = 6 * 1024 * 1024;
const TIPOS_IMAGEM = ["image/jpeg", "image/png", "image/webp"];

// Endereço de evento do Sympla, limpo (sem o que vem depois do "?"); null se não for
export function linkDoSympla(texto: string): string | null {
  try {
    const u = new URL(texto.trim());
    if (u.protocol !== "https:" || !["www.sympla.com.br", "sympla.com.br"].includes(u.hostname) || u.port || u.username) return null;
    if (!/^\/evento(-online)?\/[^/]+\/\d+\/?$/.test(u.pathname) && !/^\/[^/]+__\d+\/?$/.test(u.pathname)) return null;
    return "https://www.sympla.com.br" + u.pathname;
  } catch {
    return null;
  }
}

// Baixa só de onde a função "ok" permite, conferindo cada redirecionamento e o tamanho
async function baixar(inicio: string, ok: (u: string) => string | null, max: number) {
  let url: string = inicio;
  for (let i = 0; i < 4; i++) {
    const r = await fetch(url, { redirect: "manual", headers: { "User-Agent": "Mozilla/5.0" }, signal: AbortSignal.timeout(12000) });
    if (r.status >= 300 && r.status < 400) {
      const novo = ok(new URL(r.headers.get("location") ?? "", url).href);
      if (!novo) throw new Error("redirecionamento fora do permitido");
      await r.body?.cancel();
      url = novo;
      continue;
    }
    if (r.status === 404 || r.status === 410) throw new Error("nao-existe");
    if (!r.ok || !r.body) throw new Error("resposta " + r.status);
    const partes: Uint8Array[] = [];
    let total = 0;
    for await (const p of r.body) {
      total += p.length;
      if (total > max) throw new Error("grande demais");
      partes.push(p);
    }
    const bytes = new Uint8Array(total);
    let pos = 0;
    for (const p of partes) { bytes.set(p, pos); pos += p.length; }
    return { bytes, tipo: (r.headers.get("content-type") ?? "").split(";")[0].trim() };
  }
  throw new Error("redirecionamentos demais");
}

const limpo = (t: unknown, max = 300) => String(t ?? "").replace(/\s+/g, " ").replace(/\s+,/g, ",").trim().slice(0, max);

// deno-lint-ignore no-explicit-any
export function montarDados(e: any, link: string) {
  const a = e.eventsAddress ?? {};
  const online = !!e.onlineInfo || /ONLINE/i.test(String(e.eventType ?? ""));
  const cidade = [limpo(a.city), limpo(a.state)].filter(Boolean).join("/");
  const rua = limpo(a.address);
  const numero = limpo(a.addressNum), sala = /^\d/.test(numero) ? "" : numero;
  const partes = [limpo(a.name), sala, rua, sala ? "" : numero, limpo(a.neighborhood)].filter(Boolean);
  const detalhe = String(e.detail ?? "").replace(/<\/(p|div|li|h\d)>|<br\s*\/?>/gi, "\n").replace(/<[^>]*>/g, "")
    .replace(/&nbsp;/g, " ").replace(/&quot;/g, '"').replace(/&#0?39;/g, "'").replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&amp;/g, "&")
    .split("\n").map((l) => l.replace(/\s+/g, " ").trim()).filter(Boolean).join("\n").slice(0, 1500);
  const [di, hi] = String(e.startDate ?? "").split(" "), [df, hf] = String(e.endDate ?? "").split(" ");
  const dia = (d?: string) => (d && /^\d{4}-\d{2}-\d{2}$/.test(d) ? d : null), hora = (h?: string) => (h && /^\d{2}:\d{2}/.test(h) ? h.slice(0, 5) : null);
  return {
    titulo: limpo(e.name, 200), data_inicio: dia(di), data_fim: dia(df), hora_inicio: hora(hi), hora_fim: hora(hf),
    online, local: online ? "" : [...partes, rua.includes(limpo(a.city)) && a.city ? "" : cidade].filter(Boolean).join(", "),
    preco: e.paymentEventType === "unpaid" ? 0 : null, descricao: detalhe, organizador: limpo(e.eventsHost?.name),
    cancelado: !!e.cancelled, encerrado: !!e.isClosed, link,
  };
}

Deno.serve(async (req: Request) => {
  const cors = montarCors(req);
  const responder = (corpo: unknown, status = 200) => new Response(JSON.stringify(corpo), { status, headers: { ...cors, "Content-Type": "application/json" } });
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return responder({ error: "Método não aceito." }, 405);
  try {
    // Só a equipe: pergunta ao banco com o login de quem chamou
    const staff = await fetch(`${Deno.env.get("SUPABASE_URL")}/rest/v1/rpc/eh_staff`, {
      method: "POST",
      headers: { "Content-Type": "application/json", apikey: Deno.env.get("SUPABASE_ANON_KEY") ?? "", Authorization: req.headers.get("authorization") ?? "" },
      body: "{}",
    });
    if (!staff.ok || (await staff.json()) !== true) return responder({ error: "Só a equipe da Go Ladies pode usar." }, 403);

    const corpo = await req.json().catch(() => ({}));
    const link = linkDoSympla(String(corpo?.url ?? "").slice(0, 1000));
    if (!link) return responder({ error: "Esse não parece um link de evento do Sympla." }, 400);

    let falha = "";
    const pagina = await baixar(link, linkDoSympla, PAGINA_MAX).catch((e) => { falha = e.message; return null; });
    if (falha === "nao-existe") return responder({ error: "Não encontrei esse evento no Sympla. O link está completo?" }, 422);
    if (!pagina) return responder({ error: "Não consegui abrir esse evento no Sympla. O link está completo? Se estiver, que tal tentar de novo daqui a pouco?" }, 502);
    const html = new TextDecoder().decode(pagina.bytes);
    const bloco = html.match(/<script id="__NEXT_DATA__"[^>]*>([\s\S]*?)<\/script>/)?.[1];
    let evento = null;
    try { evento = bloco ? JSON.parse(bloco)?.props?.pageProps?.hydrationData?.eventHydration?.event : null; } catch { /* página mudou */ }
    if (!evento?.name) return responder({ error: "Não encontrei os dados do evento nessa página." }, 422);

    let imagem: { tipo: string; base64: string } | null = null;
    const soImagem = (u: string) => { try { const x = new URL(u); return x.protocol === "https:" && x.hostname === "images.sympla.com.br" && !x.port ? x.href : null; } catch { return null; } };
    const arte = soImagem(String(evento.images?.logoLarge ?? evento.logoUrl ?? ""));
    if (arte) {
      const b = await baixar(arte, soImagem, IMAGEM_MAX).catch(() => null);
      if (b && TIPOS_IMAGEM.includes(b.tipo)) {
        let s = "";
        for (let i = 0; i < b.bytes.length; i += 8192) s += String.fromCharCode(...b.bytes.subarray(i, i + 8192));
        imagem = { tipo: b.tipo, base64: btoa(s) };
      }
    }
    return responder({ dados: montarDados(evento, link), imagem });
  } catch (e) {
    console.error("ler-evento:", e);
    return responder({ error: "Não consegui ler o evento agora." }, 500);
  }
});
