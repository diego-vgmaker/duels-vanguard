# Ligando contas e Meta (Supabase + Google)

O site continua no GitHub Pages. O Supabase guarda as contas e as estatísticas.
Enquanto `ONLINE` estiver vazio no `index.html`, o site funciona exatamente como antes, 100% offline.

Tempo estimado: 20–30 minutos. Custo: R$ 0 (plano gratuito).

---

## 1. Criar o projeto no Supabase

1. Entre em <https://supabase.com> e clique em **Start your project** (dá para entrar com a conta do GitHub).
2. **New project**:
   - Name: `duels-vanguard`
   - Database password: gere uma senha forte e **guarde** (você não vai precisar mandar para ninguém).
   - Region: **South America (São Paulo)**
   - Plano: **Free**
3. Espere o projeto ficar pronto (1–2 minutos).

## 2. Criar as tabelas

1. Abra o arquivo [`supabase/schema.sql`](../supabase/schema.sql) no GitHub, clique em **Raw** e copie tudo.
2. No Supabase: menu lateral **SQL Editor** → **New query** → cole → **Run**.
3. Deve aparecer `Success. No rows returned`. Pode rodar de novo sem problema se precisar.

Isso cria: perfis (nome de jogador), partidas registradas, as funções do Meta e as regras de segurança (cada jogador só grava as próprias partidas; ninguém lê e-mails ou dados de outro jogador).

## 3. Endereços do site

**Authentication** → **URL Configuration**:

- **Site URL:** `https://diego-vgmaker.github.io/duels-vanguard/`
- **Redirect URLs** → Add URL: `https://diego-vgmaker.github.io/duels-vanguard/`

Sem isso, os links de confirmação de e-mail e o login com Google voltam para o lugar errado.

## 4. Login com e-mail e senha

Já vem ligado. Em **Authentication** → **Sign In / Providers** → **Email**, deixe **Confirm email** ligado.

> O e-mail embutido do Supabase manda poucos e-mails por hora e serve para testes.
> Quando o site tiver jogadores de verdade, configure um SMTP próprio
> (**Authentication** → **Emails** → **SMTP Settings**), por exemplo com o Resend, que tem plano gratuito.

## 5. Login com Google

**No Google Cloud** (<https://console.cloud.google.com>):

1. Crie um projeto chamado `duels-vanguard`.
2. Vá em **Google Auth Platform** (ou **APIs e serviços → Tela de consentimento OAuth**) e configure:
   - Nome do app: `duels.vanguard`
   - E-mail de suporte: o seu
   - Público: **Externo**
   - Link da política de privacidade: `https://diego-vgmaker.github.io/duels-vanguard/privacy.html`
   - Depois de salvar, clique em **Publicar app** (sem isso só contas de teste conseguem entrar). Como o site só pede nome e e-mail, não precisa de revisão do Google.
3. **Clientes** (ou **Credenciais**) → **Criar cliente OAuth** → tipo **Aplicativo da Web**:
   - Origens JavaScript autorizadas: `https://diego-vgmaker.github.io`
   - URIs de redirecionamento autorizados: a **Callback URL** que aparece no Supabase no passo abaixo
     (algo como `https://SEU-PROJETO.supabase.co/auth/v1/callback`)
4. Copie o **ID do cliente** e a **Chave secreta do cliente**.

**No Supabase:** **Authentication** → **Sign In / Providers** → **Google** → ligue, cole o ID e a chave secreta → **Save**.

## 6. Me mandar as duas chaves públicas

No Supabase, botão **Connect** no topo (ou **Project Settings** → **API**), copie:

- **Project URL** — `https://xxxx.supabase.co`
- **anon public key** (ou **publishable key**, que começa com `sb_publishable_`)

Essas duas são públicas por natureza e vão dentro do `index.html`.

> **Nunca** mande nem coloque no site a **service_role / secret key** nem a senha do banco.

Com elas eu preencho o bloco `ONLINE` no `index.html`, faço o merge e o site publica sozinho no GitHub Pages.

---

## Bom saber

- **Projeto pausado:** no plano gratuito, o Supabase pausa o projeto depois de 1 semana sem nenhum acesso. Se acontecer, entre no painel e clique em **Restore**. Com jogadores entrando, isso não acontece.
- **Ver os dados:** **Table Editor** → `profiles` (contas) e `matches_played` (partidas).
- **Testar localmente:** se quiser abrir o site no seu PC (`python -m http.server 8000`), adicione `http://localhost:8000/**` em Redirect URLs.
