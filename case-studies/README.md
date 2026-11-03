# Case studies

A case study shows how one production deployment of a pakem backend picked its products and services, and how it met
the guide's requirements with them. It is an **illustration, not part of the standard**: nothing in a case study is a
rule, and nothing in it overrides the guide.

Pakem decides how a backend is built. Which cloud it runs on, which managed Postgres and Redis it uses, which CPU
architecture and container platform it runs on, and which providers serve its frontend, files, DNS, email, logs, and
secrets are **decisions for the project that uses pakem**. A project records them in its own `AGENTS.md`
([templates/project/AGENTS.md](../templates/project/AGENTS.md) §1).

Read a case study to see the requirements of the guide made concrete, to borrow what fits your project, and to learn from
the incidents behind each choice. Do not read it as a list of products to buy.

| Case study | Backend | Database & cache | Frontend, edge, files |
|---|---|---|---|
| [AWS + Supabase + Cloudflare](aws-supabase-cloudflare/README.md) | ECS on EC2 (Graviton, arm64) behind an ALB, Terraform, GitHub Actions | Supabase Postgres through its pooler; Redis Cloud | Cloudflare Pages, Workers, R2, DNS |

## Writing a case study

- Describe **one real deployment**. The numbers (instance sizes, pool sizes, costs, timings) are what that deployment
  measured, not targets.
- Open with a sentence that says it is an illustration, not part of the standard.
- For every product or service, say **which requirement of the guide it meets** and link to that chapter, so a reader can
  swap it for their own choice and know what the replacement must do.
- Keep provider-specific detail (resource names, CLI commands, console steps, quirks) here; the guide itself stays free of
  it. A lesson that turns out to apply to any provider moves into the guide, written without the provider's name.
- Same rules as the rest of this repo: no secrets, credentials, account IDs, or project refs; placeholders for every
  example value.
