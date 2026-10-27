// Preferências da viagem (27/10/2026, schema_preferencias_viagem.sql).
// A cliente responde no pedido (cliente.html); a motorista lê no card da
// corrida (motorista.html); a equipe vê o destaque e o match no CRM.
// Arquivo igual no repo do site e no do CRM: mudou um, copie pro outro.
//
// viagens.preferencias (jsonb), tudo opcional:
//   conversa: conversar | basico | silencio
//   musica: qualquer | preferencia | sem   (+ musica_estilos [], musica_outro)
//   volume: baixo | normal
//   ar: pode | janela | nao_pode
//   temperatura: gelado | neutro | quente
//   direcao: normal | suave
//   bagagem, ajuda_entrar, cadeira_rodas, gestante, cheiro: true
//   crianca: { cadeirinha: preciso | levo, idades: [3, 6] }
//   pet: com_caixa | sem_caixa
//   carregador: lightning | usbc | microusb | sem_fio
//   compras: poucas | muitas
// motoristas.recursos (jsonb): o que ela tem no carro e o que topa
//   aceita_pet, caixa_pet, porta_malas_grande, ajuda_cadeira_rodas: true
//   cadeirinhas: [bebe_conforto, cadeirinha, elevacao]
//   carregadores: [lightning, usbc, microusb, sem_fio]
(function () {
  var CARREGADOR = { lightning: 'iPhone (Lightning)', usbc: 'USB-C', microusb: 'Micro-USB (Android mais antigo)', sem_fio: 'sem fio' };
  // Contran, Resolução 819/2021: o tipo muda com a idade
  var CADEIRINHA = {
    bebe_conforto: { nome: 'bebê conforto', faixa: 'até 1 ano', como: 'instalado de costas para a frente do carro' },
    cadeirinha: { nome: 'cadeirinha', faixa: '1 a 4 anos' },
    elevacao: { nome: 'assento de elevação', faixa: '4 a 7 anos e meio' }
  };
  var ESTILOS = ['MPB', 'Pop', 'Sertanejo', 'Gospel', 'Rock', 'Eletrônica'];

  function tipoCadeirinha(idade) {
    var n = Number(idade);
    if (idade === '' || idade == null || isNaN(n)) return null;
    if (n < 1) return 'bebe_conforto';
    if (n < 4) return 'cadeirinha';
    if (n <= 7) return 'elevacao';
    return null; // a partir de 8: só o cinto, no banco de trás
  }
  function junta(arr) { return arr.length > 1 ? arr.slice(0, -1).join(', ') + ' e ' + arr[arr.length - 1] : (arr[0] || ''); }
  function idadesDe(c) {
    return ((c && c.idades) || []).map(Number).filter(function (n) { return !isNaN(n) && n >= 0 && n <= 17; });
  }
  function textoIdade(n) { return n < 1 ? 'menos de 1 ano' : n + (n === 1 ? ' ano' : ' anos'); }

  // [ícone, texto] por extenso, do jeito que a motorista lê.
  // precisa = pede algo da motorista ou do carro (vai em destaque);
  // conforto = jeito da viagem.
  function linhas(p) {
    var precisa = [], conforto = [];
    if (!p || typeof p !== 'object') return { precisa: precisa, conforto: conforto };
    if (p.pet) precisa.push(['paw', 'Vai com pet pequeno, ' + (p.pet === 'com_caixa' ? 'com caixa de transporte' : 'sem caixa de transporte')]);
    // A motorista pode não saber a regra: cada criança vem com o tipo que
    // usa e a faixa de idade dele, e a lembrança do banco de trás.
    if (p.crianca && p.crianca.cadeirinha) {
      var ids = idadesDe(p.crianca);
      var levo = p.crianca.cadeirinha === 'levo';
      if (!ids.length) precisa.push(['mood-kid', levo ? 'Vai criança: a cliente leva a própria cadeirinha' : 'Vai criança: precisa de cadeirinha (a idade a gente confirma com a cliente)']);
      ids.forEach(function (n) {
        var t = tipoCadeirinha(n);
        var quem = n < 1 ? 'Bebê de menos de 1 ano' : 'Criança de ' + textoIdade(n);
        var uso = t ? CADEIRINHA[t].nome + ' (para ' + CADEIRINHA[t].faixa + (CADEIRINHA[t].como ? ', ' + CADEIRINHA[t].como : '') + ')' : null;
        if (!t) precisa.push(['mood-kid', quem + ': não precisa de cadeirinha, usa só o cinto de segurança']);
        else if (levo) precisa.push(['mood-kid', quem + ': a cliente leva a própria cadeirinha. Pela idade, deve ser ' + uso]);
        else precisa.push(['mood-kid', quem + ': precisa de ' + uso]);
      });
      if (ids.some(function (n) { return n < 10; }) || !ids.length) precisa.push(['info-circle', 'Pela lei, criança com menos de 10 anos viaja no banco de trás']);
    }
    if (p.cadeira_rodas) precisa.push(['wheelchair', 'Leva cadeira de rodas dobrável ou andador']);
    if (p.ajuda_entrar) precisa.push(['walk', 'Precisa de ajuda para entrar e sair do carro']);
    if (p.gestante) precisa.push(['woman', 'Está gestante']);
    if (p.compras) precisa.push(['shopping-cart', 'Está com compras de mercado: ' + (p.compras === 'muitas' ? 'muitas sacolas, precisa do porta-malas' : 'poucas sacolas')]);
    if (p.bagagem) precisa.push(['luggage', 'Precisa de ajuda com a bagagem']);
    if (p.carregador) precisa.push(['plug', 'Gostaria de carregador de celular ' + (CARREGADOR[p.carregador] || '')]);
    if (p.ar === 'nao_pode') precisa.push(['snowflake', 'Não pode usar ar-condicionado']);
    if (p.cheiro) precisa.push(['spray', 'Sensível a cheiro: sem perfume nem aromatizante no carro']);
    if (p.direcao === 'suave') precisa.push(['steering-wheel', 'Direção bem suave (enjoo, gestação ou pós-cirurgia)']);

    if (p.conversa) conforto.push(['message-circle', { conversar: 'Gosta de conversar', basico: 'Conversa só o básico', silencio: 'Prefere silêncio' }[p.conversa] || '']);
    if (p.musica === 'sem') conforto.push(['music', 'Prefere sem música']);
    else if (p.musica) {
      var est = (p.musica_estilos || []).slice();
      if (p.musica_outro) est.push(p.musica_outro);
      var vol = p.volume === 'baixo' ? ', volume baixinho' : p.volume === 'normal' ? ', volume normal' : '';
      conforto.push(['music', p.musica === 'preferencia' && est.length ? 'Música: ' + junta(est) + vol : 'Música: pode ser qualquer estilo' + vol]);
    } else if (p.volume) conforto.push(['volume', p.volume === 'baixo' ? 'Volume baixinho' : 'Volume normal']);
    if (p.ar === 'pode') conforto.push(['snowflake', 'Pode ligar o ar-condicionado']);
    if (p.ar === 'janela') conforto.push(['wind', 'Prefere janela aberta']);
    if (p.temperatura) conforto.push(['temperature', { gelado: 'Prefere mais gelado', neutro: 'Temperatura neutra', quente: 'Prefere mais quente' }[p.temperatura] || '']);
    if (p.direcao === 'normal') conforto.push(['steering-wheel', 'Direção normal']);
    return { precisa: precisa, conforto: conforto };
  }

  // O que a motorista não tem para o que a viagem pede. Vazio = atende tudo.
  function faltas(p, r) {
    var f = [];
    if (!p) return f;
    r = r || {};
    var cads = r.cadeirinhas || [], cars = r.carregadores || [];
    if (p.pet && !r.aceita_pet) f.push('não marcou que aceita pet');
    else if (p.pet === 'sem_caixa' && !r.caixa_pet) f.push('não tem caixa de pet');
    if (p.crianca && p.crianca.cadeirinha === 'preciso') {
      var tipos = idadesDe(p.crianca).map(tipoCadeirinha).filter(Boolean);
      if (!tipos.length && !idadesDe(p.crianca).length && !cads.length) f.push('não tem cadeirinha');
      tipos.forEach(function (t) { if (cads.indexOf(t) === -1 && f.indexOf('não tem ' + CADEIRINHA[t].nome) === -1) f.push('não tem ' + CADEIRINHA[t].nome); });
    }
    if (p.carregador && cars.indexOf(p.carregador) === -1) f.push('não tem carregador ' + (CARREGADOR[p.carregador] || ''));
    if (p.cadeira_rodas && !(r.porta_malas_grande && r.ajuda_cadeira_rodas)) f.push('não marcou cadeira de rodas');
    if (p.compras === 'muitas' && !r.porta_malas_grande) f.push('porta-malas pequeno');
    return f;
  }

  function textosRecursos(r) {
    r = r || {};
    var t = [];
    if (r.aceita_pet) t.push('aceita pet' + (r.caixa_pet ? ' (tem caixa)' : ''));
    (r.cadeirinhas || []).forEach(function (c) { if (CADEIRINHA[c]) t.push(CADEIRINHA[c].nome); });
    if ((r.carregadores || []).length) t.push('carregador ' + junta(r.carregadores.map(function (c) { return CARREGADOR[c] || c; })));
    if (r.porta_malas_grande) t.push('porta-malas grande');
    if (r.ajuda_cadeira_rodas) t.push('ajuda com cadeira de rodas');
    return t;
  }

  // Formulário "O que tenho no carro e o que topo" (painel da motorista e CRM)
  var RECURSOS_SIMPLES = [
    ['aceita_pet', 'paw', 'Aceito pet pequeno'],
    ['caixa_pet', 'paw', 'Tenho caixa de transporte para pet'],
    ['porta_malas_grande', 'luggage', 'Porta-malas grande (cadeira de rodas, andador ou muitas compras)'],
    ['ajuda_cadeira_rodas', 'wheelchair', 'Topo ajudar com cadeira de rodas ou andador']
  ];
  function esc(s) { return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]; }); }
  function icone(n) { return window.ic ? window.ic(n) : ''; }
  function htmlRecursos(r) {
    r = r || {};
    var h = '<div class="gl-recursos">';
    RECURSOS_SIMPLES.forEach(function (x) {
      h += '<label class="gl-rec-linha"><input type="checkbox" data-rec="' + x[0] + '"' + (r[x[0]] ? ' checked' : '') + '> ' + icone(x[1]) + ' ' + esc(x[2]) + '</label>';
    });
    h += '<div class="gl-rec-tit">' + icone('mood-kid') + ' Cadeirinha de criança que tenho</div>';
    Object.keys(CADEIRINHA).forEach(function (k) {
      h += '<label class="gl-rec-linha"><input type="checkbox" data-rec-lista="cadeirinhas" value="' + k + '"' + ((r.cadeirinhas || []).indexOf(k) !== -1 ? ' checked' : '') + '> ' + esc(CADEIRINHA[k].nome.charAt(0).toUpperCase() + CADEIRINHA[k].nome.slice(1)) + ' <span class="gl-rec-sub">(' + CADEIRINHA[k].faixa + ')</span></label>';
    });
    h += '<div class="gl-rec-tit">' + icone('plug') + ' Carregador de celular que tenho no carro</div>';
    Object.keys(CARREGADOR).forEach(function (k) {
      h += '<label class="gl-rec-linha"><input type="checkbox" data-rec-lista="carregadores" value="' + k + '"' + ((r.carregadores || []).indexOf(k) !== -1 ? ' checked' : '') + '> ' + esc(CARREGADOR[k].charAt(0).toUpperCase() + CARREGADOR[k].slice(1)) + '</label>';
    });
    return h + '</div>';
  }
  function lerRecursos(el) {
    var r = { cadeirinhas: [], carregadores: [] };
    el.querySelectorAll('[data-rec]').forEach(function (cb) { if (cb.checked) r[cb.dataset.rec] = true; });
    el.querySelectorAll('[data-rec-lista]').forEach(function (cb) { if (cb.checked) r[cb.dataset.recLista].push(cb.value); });
    return r;
  }

  window.Preferencias = {
    CARREGADOR: CARREGADOR, CADEIRINHA: CADEIRINHA, ESTILOS: ESTILOS,
    tipoCadeirinha: tipoCadeirinha, linhas: linhas, faltas: faltas,
    textosRecursos: textosRecursos, htmlRecursos: htmlRecursos, lerRecursos: lerRecursos,
    vazia: function (p) { var l = linhas(p); return !l.precisa.length && !l.conforto.length; }
  };
})();
