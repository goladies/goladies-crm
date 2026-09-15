# Templates de e-mail do Supabase Auth (Go Ladies)

Onde colar: **Supabase → Authentication → Emails → aba Templates**. Cada template tem um campo *Subject heading* e um campo *Message body* (em HTML). Copiar o assunto e o corpo de cada bloco abaixo. As variáveis entre `{{ }}` são preenchidas pelo Supabase, não mexer.

Remetente já configurado em SMTP Settings: `Go Ladies <contato@goladies.com.br>`.

---

## 1. Reset Password (Esqueci minha senha)

**Subject heading:**
```
Redefinir sua senha · Go Ladies
```

**Message body:**
```html
<div style="font-family:Arial,Helvetica,sans-serif;max-width:520px;margin:0 auto;padding:24px;color:#1a1a1a;">
  <h2 style="color:#FF2D9C;margin:0 0 16px;">Redefinir sua senha</h2>
  <p>Oi! Recebemos um pedido pra trocar a senha da sua conta na Go Ladies ({{ .Email }}).</p>
  <p>Clique no botão abaixo pra escolher uma senha nova:</p>
  <p style="margin:24px 0;">
    <a href="{{ .ConfirmationURL }}" style="background:#FF2D9C;color:#fff;text-decoration:none;padding:12px 24px;border-radius:24px;display:inline-block;font-weight:bold;">Criar senha nova</a>
  </p>
  <p style="font-size:13px;color:#666;">Se o botão não abrir, copie e cole este link no navegador:<br>
  <a href="{{ .ConfirmationURL }}" style="color:#FF2D9C;word-break:break-all;">{{ .ConfirmationURL }}</a></p>
  <p style="font-size:13px;color:#666;">Se você não pediu isso, pode ignorar este e-mail; sua senha continua a mesma.</p>
  <hr style="border:0;border-top:1px solid #eee;margin:24px 0;">
  <p style="font-size:12px;color:#999;margin:0;">Go Ladies · O mundo dos carros para elas<br>contato@goladies.com.br</p>
</div>
```

---

## 2. Confirm signup (Confirmar cadastro)

**Subject heading:**
```
Confirme seu e-mail · Go Ladies
```

**Message body:**
```html
<div style="font-family:Arial,Helvetica,sans-serif;max-width:520px;margin:0 auto;padding:24px;color:#1a1a1a;">
  <h2 style="color:#FF2D9C;margin:0 0 16px;">Bem-vinda à Go Ladies!</h2>
  <p>Falta só confirmar que este e-mail ({{ .Email }}) é seu.</p>
  <p style="margin:24px 0;">
    <a href="{{ .ConfirmationURL }}" style="background:#FF2D9C;color:#fff;text-decoration:none;padding:12px 24px;border-radius:24px;display:inline-block;font-weight:bold;">Confirmar meu e-mail</a>
  </p>
  <p style="font-size:13px;color:#666;">Se o botão não abrir, copie e cole este link no navegador:<br>
  <a href="{{ .ConfirmationURL }}" style="color:#FF2D9C;word-break:break-all;">{{ .ConfirmationURL }}</a></p>
  <p style="font-size:13px;color:#666;">Se você não criou uma conta na Go Ladies, pode ignorar este e-mail.</p>
  <hr style="border:0;border-top:1px solid #eee;margin:24px 0;">
  <p style="font-size:12px;color:#999;margin:0;">Go Ladies · O mundo dos carros para elas<br>contato@goladies.com.br</p>
</div>
```

---

## 3. Magic Link (Entrar sem senha)

**Subject heading:**
```
Seu link de acesso · Go Ladies
```

**Message body:**
```html
<div style="font-family:Arial,Helvetica,sans-serif;max-width:520px;margin:0 auto;padding:24px;color:#1a1a1a;">
  <h2 style="color:#FF2D9C;margin:0 0 16px;">Seu link de acesso</h2>
  <p>Clique no botão abaixo pra entrar na sua conta da Go Ladies ({{ .Email }}). O link vale por pouco tempo e só funciona uma vez.</p>
  <p style="margin:24px 0;">
    <a href="{{ .ConfirmationURL }}" style="background:#FF2D9C;color:#fff;text-decoration:none;padding:12px 24px;border-radius:24px;display:inline-block;font-weight:bold;">Entrar agora</a>
  </p>
  <p style="font-size:13px;color:#666;">Se o botão não abrir, copie e cole este link no navegador:<br>
  <a href="{{ .ConfirmationURL }}" style="color:#FF2D9C;word-break:break-all;">{{ .ConfirmationURL }}</a></p>
  <p style="font-size:13px;color:#666;">Se você não pediu este link, pode ignorar este e-mail.</p>
  <hr style="border:0;border-top:1px solid #eee;margin:24px 0;">
  <p style="font-size:12px;color:#999;margin:0;">Go Ladies · O mundo dos carros para elas<br>contato@goladies.com.br</p>
</div>
```

---

## 4. Invite user (Convite)

**Subject heading:**
```
Você foi convidada para a Go Ladies
```

**Message body:**
```html
<div style="font-family:Arial,Helvetica,sans-serif;max-width:520px;margin:0 auto;padding:24px;color:#1a1a1a;">
  <h2 style="color:#FF2D9C;margin:0 0 16px;">Você foi convidada!</h2>
  <p>Criamos um acesso pra você ({{ .Email }}) na plataforma da Go Ladies. Clique no botão pra aceitar o convite e definir sua senha:</p>
  <p style="margin:24px 0;">
    <a href="{{ .ConfirmationURL }}" style="background:#FF2D9C;color:#fff;text-decoration:none;padding:12px 24px;border-radius:24px;display:inline-block;font-weight:bold;">Aceitar convite</a>
  </p>
  <p style="font-size:13px;color:#666;">Se o botão não abrir, copie e cole este link no navegador:<br>
  <a href="{{ .ConfirmationURL }}" style="color:#FF2D9C;word-break:break-all;">{{ .ConfirmationURL }}</a></p>
  <hr style="border:0;border-top:1px solid #eee;margin:24px 0;">
  <p style="font-size:12px;color:#999;margin:0;">Go Ladies · O mundo dos carros para elas<br>contato@goladies.com.br</p>
</div>
```

---

## 5. Change Email Address (Trocar e-mail)

**Subject heading:**
```
Confirme seu novo e-mail · Go Ladies
```

**Message body:**
```html
<div style="font-family:Arial,Helvetica,sans-serif;max-width:520px;margin:0 auto;padding:24px;color:#1a1a1a;">
  <h2 style="color:#FF2D9C;margin:0 0 16px;">Confirme seu novo e-mail</h2>
  <p>Recebemos um pedido pra trocar o e-mail da sua conta na Go Ladies de {{ .Email }} para {{ .NewEmail }}.</p>
  <p style="margin:24px 0;">
    <a href="{{ .ConfirmationURL }}" style="background:#FF2D9C;color:#fff;text-decoration:none;padding:12px 24px;border-radius:24px;display:inline-block;font-weight:bold;">Confirmar troca</a>
  </p>
  <p style="font-size:13px;color:#666;">Se o botão não abrir, copie e cole este link no navegador:<br>
  <a href="{{ .ConfirmationURL }}" style="color:#FF2D9C;word-break:break-all;">{{ .ConfirmationURL }}</a></p>
  <p style="font-size:13px;color:#666;">Se você não pediu isso, ignore este e-mail e sua conta continua com o e-mail atual.</p>
  <hr style="border:0;border-top:1px solid #eee;margin:24px 0;">
  <p style="font-size:12px;color:#999;margin:0;">Go Ladies · O mundo dos carros para elas<br>contato@goladies.com.br</p>
</div>
```

---

## Notificações de segurança (aba Templates → seção Security)

Ligadas em 11/09/2026: só **Password changed** e **Email address changed**. As outras cinco (telefone, métodos de login, MFA) ficam desligadas porque o CRM não usa esses recursos.

### Password changed

**Subject heading:** `Sua senha foi alterada · Go Ladies`

```html
<div style="font-family:Arial,Helvetica,sans-serif;max-width:520px;margin:0 auto;padding:24px;color:#1a1a1a;">
  <h2 style="color:#FF2D9C;margin:0 0 16px;">Sua senha foi alterada</h2>
  <p>A senha da sua conta na Go Ladies ({{ .Email }}) acabou de ser trocada.</p>
  <p>Se foi você, não precisa fazer nada.</p>
  <p style="font-size:13px;color:#666;">Se não foi você, fale com a gente agora pelo WhatsApp (51) 98972-5128 ou respondendo este e-mail.</p>
  <hr style="border:0;border-top:1px solid #eee;margin:24px 0;">
  <p style="font-size:12px;color:#999;margin:0;">Go Ladies · O mundo dos carros para elas<br>contato@goladies.com.br</p>
</div>
```

### Email address changed

**Subject heading:** `Seu e-mail foi alterado · Go Ladies`

```html
<div style="font-family:Arial,Helvetica,sans-serif;max-width:520px;margin:0 auto;padding:24px;color:#1a1a1a;">
  <h2 style="color:#FF2D9C;margin:0 0 16px;">Seu e-mail foi alterado</h2>
  <p>O e-mail da sua conta na Go Ladies foi trocado para {{ .NewEmail }}.</p>
  <p>Se foi você, não precisa fazer nada.</p>
  <p style="font-size:13px;color:#666;">Se não foi você, fale com a gente agora pelo WhatsApp (51) 98972-5128 ou respondendo este e-mail.</p>
  <hr style="border:0;border-top:1px solid #eee;margin:24px 0;">
  <p style="font-size:12px;color:#999;margin:0;">Go Ladies · O mundo dos carros para elas<br>contato@goladies.com.br</p>
</div>
```

---

## 6. Reauthentication (Código de confirmação)

Este não tem link, só um código de 6 dígitos que a pessoa digita.

**Subject heading:**
```
Seu código de confirmação · Go Ladies
```

**Message body:**
```html
<div style="font-family:Arial,Helvetica,sans-serif;max-width:520px;margin:0 auto;padding:24px;color:#1a1a1a;">
  <h2 style="color:#FF2D9C;margin:0 0 16px;">Seu código de confirmação</h2>
  <p>Use o código abaixo pra confirmar a ação na sua conta da Go Ladies:</p>
  <p style="font-size:32px;letter-spacing:6px;font-weight:bold;color:#1a1a1a;margin:24px 0;">{{ .Token }}</p>
  <p style="font-size:13px;color:#666;">O código vale por pouco tempo. Se você não pediu isso, pode ignorar este e-mail.</p>
  <hr style="border:0;border-top:1px solid #eee;margin:24px 0;">
  <p style="font-size:12px;color:#999;margin:0;">Go Ladies · O mundo dos carros para elas<br>contato@goladies.com.br</p>
</div>
```
