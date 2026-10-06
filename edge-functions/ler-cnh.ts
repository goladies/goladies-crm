// Go Ladies — Edge Function "ler-cnh"
// Lê uma foto ou PDF da CNH da motorista com IA (Claude) e devolve os dados
// prontos pra preencher o cadastro. Não salva nada sozinha — quem chama
// decide o que fazer com o resultado.
//
// COMO IMPLANTAR (primeira vez):
// 1. Supabase → seu projeto → Edge Functions → Create a new function
// 2. Nome da função: ler-cnh
// 3. Cole todo este arquivo no editor e clique em Deploy
// 4. Edge Functions → Secrets → adicione ANTHROPIC_API_KEY com a chave
//    (console.anthropic.com → API Keys → Create Key)
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
      throw new Error("Envie uma foto (JPG/PNG/WEBP) ou PDF da CNH.");
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
              nome_completo: { type: "string", description: "Nome completo do condutor, como impresso no documento. Vazio se ilegível." },
              data_nascimento: { type: "string", description: "Data de nascimento. Está no campo '3 DATA, LOCAL E UF DE NASCIMENTO', que traz data, cidade e UF juntos separados por vírgula — pegue só a primeira parte (a data) e converta pra AAAA-MM-DD. Exemplo: se o campo mostra '08/08/1981, PORTO ALEGRE, RS', o valor aqui é '1981-08-08'. Vazio se ilegível." },
              cpf: { type: "string", description: "CPF como impresso (com pontuação se houver). Vazio se ilegível." },
              numero_registro: { type: "string", description: "Número de registro da CNH. Vazio se ilegível." },
              categoria: { type: "string", description: "Categoria da habilitação. Use o campo rotulado 'CAT HAB' (ou 'Categoria') na frente do documento — NÃO use o campo 'ACC', que é outra informação. Se o verso do documento também estiver na imagem, confira a grade de categorias (colunas 9-12): a(s) categoria(s) com uma data preenchida na linha são as válidas, use isso pra confirmar ou corrigir o que leu na frente. Ex: 'B', 'AB', 'D'. Vazio se ilegível." },
              validade: { type: "string", description: "Data de validade no formato AAAA-MM-DD. Vazio se ilegível." },
              tem_ear: { anyOf: [{ type: "boolean" }, { type: "null" }], description: "true se o campo de observações do documento contém 'EAR' (Exerce Atividade Remunerada), false se as observações estão visíveis e não contêm EAR, null se não foi possível ler o campo de observações." },
            },
            required: ["nome_completo", "data_nascimento", "cpf", "numero_registro", "categoria", "validade", "tem_ear"],
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
            { type: "text", text: "Extraia os dados desta CNH (Carteira Nacional de Habilitação) brasileira. Se algum campo não estiver legível ou não existir no documento, devolva string vazia (ou null em tem_ear)." },
          ],
        },
      ],
    });
    await registrarUsoIa("ler-cnh", response);

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
