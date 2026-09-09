# CLAUDE.md

Project instructions for Claude Code working in this repository.

## Project overview

This repo deploys **only** the Databricks-side adapter for Netskope **DLP On
Demand (DLPoD)** — a small Lambda that translates between the Databricks
Unity AI Gateway "External Policy Direct HTTP API" contract and DLPoD's own
REST inspection API, because the two speak incompatible schemas. It
**assumes a DLPoD appliance is already deployed** and tethered to your
Netskope tenant, reachable via an internal ALB — this repo does not deploy
the appliance itself (see `NOTICE`).

## Architecture

```
Databricks Unity AI Gateway (External Policy)
        │  OAuth M2M bearer token
        ▼
API Gateway + Cognito  →  Lambda (translation adapter)
        │  VPC-internal HTTPS, no NAT needed
        ▼
Internal ALB  →  DLPoD appliance  →  Verdict
```

The Lambda:
1. Extracts prompt/response text (and image content, since OCR support was
   added) from the Databricks event, handling both Chat Completions and
   Responses API payload shapes.
2. POSTs a `multipart/form-data` request to DLPoD's sync `/inspections`
   endpoint per content item (text, plus each image found) — run
   **concurrently** via `ThreadPoolExecutor` when there's more than one, so
   a mixed text+image message doesn't serialize DLPoD round-trip latency
   against Databricks' ~5s `pre_call` timeout budget.
3. Parses the `multipart/mixed` response and maps `verdict: hit` → `DENY`,
   `verdict: no_hit` → `ALLOW`. Any error/timeout/unrecognized verdict fails
   closed (`DENY`).

## Databricks adapter — hard-won gotchas

These were all discovered by testing against a **live** Databricks workspace
and a **live** DLPoD appliance, not just reading the contract docs:

- **Response shape must be flat**: `{"result": "ALLOW"|"DENY", "reason": "..."}`.
  Not a nested `{"decision": {...}}`. Getting this wrong means Databricks
  can't find `result` at all and fails closed to DENY on *every* response.
- **`event.type` values are lowercase**: `model_call`, `model_result`,
  `tool_call`, `tool_result`.
- **`config.policy_config` may arrive as a JSON-encoded string, not an
  object.** Databricks documents it as an opaque pass-through it "never
  parses." Always normalize (`json.loads` if it's a `str`) before calling
  `.get()` on it.
- **The model/tool payload shape varies** — classic Chat Completions
  (`messages: [{role, content: "..."}]`) or the newer Responses API
  (`input: [{role, content: [{type: "input_text", text: "..."}]}]`). Handle
  both, and extract only the current user turn's content — verify with a
  differential test (a red-herring policy-violating phrase in a *prior*
  turn shouldn't affect a benign current turn's verdict).
- **`DLP_DLPAAS_FEATURE_ENABLE_OCR`** must be enabled on the Netskope
  backend per-tenant before DLPoD will OCR image content at all. Without
  it, `/inspections` silently returns `no_hit` on images regardless of
  contents — looks like "images aren't supported," but is actually just
  this flag. Not something the adapter/template can control.
- **OCR test images need to actually be legible.** A tiny/default bitmap
  font can produce a false-negative `no_hit` purely from misread OCR — use
  a real font at a readable size when testing, or a negative result is
  inconclusive, not proof of anything.
- **`x-netskope-generate-incidents: true` must be set on every DLPoD
  `/inspections` call**, or matches still correctly enforce (DENY) but
  silently never post an alert/incident to the management plane — nothing
  shows up in SkopeIT even though blocking works. The response header
  `x-netskope-incidents-posted` confirms whether it actually posted; the
  adapter surfaces this in its DENY reason (`incident_posted=true/false`).
- **DLPoD sync `/inspections` only supports `verdict: summary`/`details`**,
  not `forensics` (that needs the async `/inspections/jobs` two-call
  polling flow, which doesn't fit Databricks' timeout budget).
- **OAuth M2M is the only supported auth method** for Databricks External
  Policies. Amazon Cognito's User Pool + Resource Server + client-credentials
  App Client is a fast way to stand up a real OAuth2 token endpoint.
- **A plain Lambda Function URL (`AuthType: NONE`) may get a blanket 403**
  from the deploying AWS account/org — many enterprises block public,
  unauthenticated Function URLs at the account/org level. Route through API
  Gateway instead (invokes via the `apigateway.amazonaws.com` service
  principal, and gives a native JWT authorizer for the Cognito token).
- **`aws cloudformation deploy --tags` is unreliable when retagging** a
  stack that already has tags with the same keys — errors with a misleading
  "Tag [Key] contained invalid characters" message, and separately,
  *omitting* `--tags` on `deploy` clears all existing stack tags. Apply
  tags via a separate `update-stack --use-previous-template --tags ...`
  call instead — the deploy script already does this.
- **Databricks propagates policy changes through a config cache** — wait
  60-90 seconds after creating/attaching a policy before testing.
- **Built-in, Databricks-hosted foundation models often live in a
  Databricks-owned system schema** (commonly `system.ai`). Attaching a
  policy there needs `MANAGE` on that schema, which may need an admin
  grant. To validate the integration without waiting on that, register
  your own model/provider service in a catalog/schema you own first.
- **The UC HTTP Connection UI location varies by workspace version** —
  found via **Catalog → gear icon (top of the Catalog panel) →
  Connections**, not the `Connect`/`Create` buttons in the main Catalog
  Explorer pane (those are for storage credentials/generic connectors).
  Look for a **Policies** tab (Beta) on the specific model/provider/MCP
  service page for attaching an External Policy — not a schema-level
  "Policies" page (that's Unity Catalog's unrelated ABAC feature).

## Repository layout

| Path | Purpose |
|------|---------|
| `templates/databricks-adapter.yaml` | The Databricks adapter CloudFormation template (Lambda + API Gateway + Cognito). |
| `deploy-databricks-adapter.ps1` | Deploys the adapter; reads `.env`. |
| `docs/databricks-adapter.md` | Adapter technical reference, full request/response contract, troubleshooting. |
| `docs/dlpod-databricks-flow.excalidraw` | Editable diagram of the call flow. |
| `Netskope-DLPoD-Databricks-Solutions-Guide.docx` | Full illustrated customer-facing deployment guide. |

## Deployment

```powershell
cp .env.example .env   # fill in VPC_ID, LAMBDA_SUBNET_IDS
./deploy-databricks-adapter.ps1
# ... configure Databricks (UC HTTP Connection + External Policy attachment) ...
```

The template is fully self-contained (Lambda code inlined), so there is no
build step and no S3 upload.

## Rules & gotchas

- **This repo assumes a DLPoD appliance already exists.** Don't add
  appliance-deployment resources (ASG, Step Functions tethering, license
  key handling) to this template — that's a separate, out-of-scope
  deployment.
- **Don't commit secrets.** `.env`, `*.pem`, `*.key` are git-ignored.

## Attribution

The Databricks adapter is original work — see `NOTICE` and `LICENSE`. It
pairs with the sibling
[databricks-plugin-netskope-ai-guardrail](https://github.com/sandiegojenkins/databricks-plugin-netskope-ai-guardrail)
repo, which follows the same adapter pattern for the separate AI Guardrails
on Demand product.

## Related resources

- [DLP On Demand Documentation](https://docs.netskope.com/en/data-loss-prevention-on-demand/)
- [Netskope OCR](https://docs.netskope.com/en/ocr)
- [Netskope AI Gateway Documentation](https://docs.netskope.com/en/ai-gateway/)
