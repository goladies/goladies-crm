// Go Ladies — Edge Function "ler-crlv"
// Lê uma foto ou PDF do CRLV (documento do carro) da motorista com IA
// (Claude) e devolve os dados prontos pra preencher o cadastro. Não salva
// nada sozinha — quem chama decide o que fazer com o resultado.
//
// COMO IMPLANTAR (primeira vez):
// 1. Supabase → seu projeto → Edge Functions → Create a new function
// 2. Nome da função: ler-crlv
// 3. Cole todo este arquivo no editor e clique em Deploy
// 4. Edge Functions → Secrets → confirme que ANTHROPIC_API_KEY já existe
//    (a mesma criada pra ler-cnh serve pras duas funções)
// 5. Confirme que "Verify JWT" está ligado nas configurações da função
//    (é o padrão) — assim só quem está logada no CRM consegue chamar.
// 6. Se já existia antes: cole este arquivo atualizado e clique em Deploy
//    de novo — a mudança só vale depois de reimplantar.

import Anthropic from "npm:@anthropic-ai/sdk";

// Só o painel do CRM chama essa function, então o CORS aceita só o endereço
// dele em vez de qualquer origem. Os dois hostnames ficam liberados durante a
// troca de domínio: o antigo redireciona pro novo, mas quem tiver o link velho
// aberto no celular continua conseguindo enviar a foto.
const ORIGENS_LIBERADAS = [
  "https://crm.goladies.com.br",
  "https://crm.ladiesindrive.com.br",
];

function montarCors(req: Request) {
  const origem = req.headers.get("origin") ?? "";
  return {
    "Access-Control-Allow-Origin": ORIGENS_LIBERADAS.includes(origem) ? origem : ORIGENS_LIBERADAS[0],
    "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Vary": "Origin",
  };
}

// Anota os tokens de cada chamada em uso_ia (custo de IA por recurso no CRM).
// SUPABASE_URL e SUPABASE_SERVICE_ROLE_KEY já existem em toda Edge Function.
// Nunca deixa o registro de custo quebrar a resposta.
async function registrarUsoIa(recurso: string, response: { model: string; usage: unknown }) {
  try {
    const chave = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
    await fetch(`${Deno.env.get("SUPABASE_URL")}/rest/v1/rpc/registrar_uso_ia`, {
      method: "POST",
      headers: { "Content-Type": "application/json", apikey: chave, Authorization: `Bearer ${chave}` },
      body: JSON.stringify({ p_recurso: recurso, p_modelo: response.model, p_uso: response.usage }),
    });
  } catch { /* sem registro, segue */ }
}

const TIPOS_ACEITOS: Record<string, string> = {
  "image/jpeg": "image/jpeg",
  "image/png": "image/png",
  "image/webp": "image/webp",
  "application/pdf": "application/pdf",
};

const TAMANHO_MAXIMO_BYTES = 10 * 1024 * 1024; // 10MB

Deno.serve(async (req) => {
  const corsHeaders = montarCors(req);

  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const formData = await req.formData();
    const arquivo = formData.get("arquivo");
    if (!(arquivo instanceof File)) {
      throw new Error("Nenhum arquivo enviado.");
    }
    const mediaType = TIPOS_ACEITOS[arquivo.type];
    if (!mediaType) {
      throw new Error("Envie uma foto (JPG/PNG/WEBP) ou PDF do CRLV.");
    }
    if (arquivo.size > TAMANHO_MAXIMO_BYTES) {
      throw new Error("Arquivo muito grande (máximo 10MB).");
    }

    const bytes = new Uint8Array(await arquivo.arrayBuffer());
    let binary = "";
    for (let i = 0; i < bytes.length; i++) binary += String.fromCharCode(bytes[i]);
    const base64 = btoa(binary);

    const documentoBlock = mediaType === "application/pdf"
      ? { type: "document" as const, source: { type: "base64" as const, media_type: "application/pdf" as const, data: base64 } }
      : { type: "image" as const, source: { type: "base64" as const, media_type: mediaType as "image/jpeg" | "image/png" | "image/webp", data: base64 } };

    const client = new Anthropic({ apiKey: Deno.env.get("ANTHROPIC_API_KEY") });

    // Opus 5.5 (05/10/2026): não aceita mais "forçar ferramenta", então a
    // leitura sai em JSON pelo formato estruturado (output_config.format),
    // que garante o formato do schema. Se a IA recusar por segurança, a
    // própria API tenta de novo num modelo reserva (fallbacks: "default").
    const response = await client.beta.messages.create({
      model: "claude-opus-5-5",
      max_tokens: 4000,
      output_config: {
        effort: "low",
        format: {
          type: "json_schema",
          schema: {
            type: "object",
            properties: {
              placa: { type: "string", description: "Placa do veículo. Vazio se ilegível." },
              marca: { type: "string", description: "Marca do veículo, ex: 'Fiat'. Vazio se ilegível." },
              modelo: { type: "string", description: "Modelo do veículo, ex: 'Argo'. Vazio se ilegível." },
              ano_fabricacao: { type: "string", description: "Ano de fabricação. Vazio se ilegível." },
              ano_modelo: { type: "string", description: "Ano do modelo. Vazio se ilegível." },
              cor: { type: "string", description: "Cor predominante do veículo. Vazio se ilegível." },
              combustivel: { type: "string", description: "Combustível/motorização, ex: 'Flex', 'Diesel'. Vazio se ilegível." },
              renavam: { type: "string", description: "Número do RENAVAM. Vazio se ilegível." },
              chassi: { type: "string", description: "Número do chassi. Vazio se ilegível." },
              proprietario_nome: { type: "string", description: "Nome do proprietário impresso no documento. Vazio se ilegível." },
            },
            required: ["placa", "marca", "modelo", "ano_fabricacao", "ano_modelo", "cor", "combustivel", "renavam", "chassi", "proprietario_nome"],
            additionalProperties: false,
          },
        },
      },
      betas: ["server-side-fallback-2026-07-01"],
      fallbacks: "default",
      messages: [
        {
          role: "user",
          content: [
            documentoBlock,
            { type: "text", text: "Extraia os dados deste CRLV (documento de veículo) brasileiro. Se algum campo não estiver legível ou não existir no documento, devolva string vazia." },
          ],
        },
      ],
    });
    await registrarUsoIa("ler-crlv", response);

    const bloco = response.content.find((b) => b.type === "text");
    let dados: unknown = null;
    if (response.stop_reason !== "refusal" && response.stop_reason !== "max_tokens" && bloco && bloco.type === "text") {
      try { dados = JSON.parse(bloco.text); } catch { dados = null; }
    }
    if (!dados) {
      throw new Error("A IA não conseguiu ler o documento. Tente outra foto.");
    }

    return new Response(JSON.stringify({ dados }), {
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  } catch (e) {
    return new Response(JSON.stringify({ error: e instanceof Error ? e.message : String(e) }), {
      status: 500,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
});
