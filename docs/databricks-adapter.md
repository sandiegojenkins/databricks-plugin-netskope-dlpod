# Databricks Unity AI Gateway ↔ DLPoD Adapter — Technical Reference

## Architecture

```
Databricks Unity AI Gateway
  │  External Policy "Direct HTTP API" (OAuth2 client-credentials)
  ▼
API Gateway (HTTP API, Cognito JWT authorizer)
  ▼
Lambda adapter  ──VPC-local──►  DLPoD internal ALB (self-signed cert)
  │                                    │
  │  translates {event, config}        ▼
  │  → DLPoD /inspections          DLPoD appliance
  ▼
{"result": "ALLOW"|"DENY", "reason": "..."}
```

No PrivateLink, no Network Connectivity Config (NCC), no Databricks
Enterprise-tier requirement, no custom `pyfunc` evaluator model serving
endpoint. Databricks calls the Lambda adapter directly as an **External
Policy** over the public internet (API Gateway + OAuth2 M2M), and the
Lambda reaches DLPoD over a normal VPC-local path.

Template: [`templates/databricks-adapter.yaml`](../templates/databricks-adapter.yaml).
Deploy: [`deploy-databricks-adapter.ps1`](../deploy-databricks-adapter.ps1).

## What it does

- Extracts the prompt/response text and any image content from a
  Databricks `model_call`/`model_result`/`tool_call`/`tool_result` event,
  handling both the Chat Completions and Responses API payload shapes.
- Sends it to DLPoD's sync `/inspections` API against the DLP profile(s)
  configured in the Databricks connection's `policy_config`.
- Maps `verdict: hit` → `DENY` (with the matched profile/severity in the
  reason), `verdict: no_hit` → `ALLOW`. Any transport error, timeout, or
  unrecognized verdict fails closed (`DENY`), matching the Databricks
  contract's own fail-closed behavior.

## Image content (OCR-based DLP)

Databricks messages can carry image content blocks — a user pasting a
screenshot into chat, for example — not just text. The adapter detects
these (`image_url` / `input_image` content blocks), decodes inline base64
`data:` URIs (or best-effort fetches a remote URL — this Lambda has no
guaranteed internet egress, so an unreachable URL fails closed with a clear
reason), and inspects each image the same way as text: as the multipart
`content` part of a DLPoD `/inspections` call. DLPoD OCRs the image content
and scans it against the same DLP profiles as text.

When a message has both text and one or more images, the adapter runs one
inspection call per content item **concurrently** (not serially), so a
mixed message doesn't multiply the DLPoD round-trip latency against
Databricks' ~5s `pre_call` timeout budget. It denies on the first hit found,
across any content item.

**Prerequisite:** OCR only works if the Netskope backend feature flag
`DLP_DLPAAS_FEATURE_ENABLE_OCR` is enabled for the tenant — this isn't
something the adapter/Lambda controls. Without it, DLPoD's `/inspections`
API silently returns `no_hit` on image content regardless of what's in the
image (confirmed empirically, not a documented limitation). Ask your
Netskope account team to enable it if image DLP doesn't seem to be catching
anything.

**Image quality matters.** A blurry, tiny-font, or low-resolution image can
produce a false-negative `no_hit` purely from OCR misreading the text — not
a policy gap. If a known-sensitive test image isn't triggering a DLP hit,
try a larger/clearer rendering before concluding the profile or flag is
wrong.

## SkopeIT alerts

By default, a DLPoD `/inspections` call evaluates and blocks correctly but
**does not** post an alert/incident to the Netskope management plane — the
match happens, but nothing shows up in SkopeIT. This requires the request
header `x-netskope-generate-incidents: true`, which the adapter always sets
(controlled by the `GenerateIncidents` CloudFormation parameter, default
`true`). The DENY reason returned to Databricks echoes DLPoD's own
`x-netskope-incidents-posted` response header (`incident_posted=true/false`)
so this is verifiable without needing Lambda logs.

If `GenerateIncidents` is left at its default, a DLP block should appear in
SkopeIT under Alert Name **"DLP On Demand"**, Application
**DatabricksAIGateway**, with the matched DLP Profile/Rule and the inspected
object name.

## Deployment

```powershell
cp .env.example .env   # fill in VPC_ID, LAMBDA_SUBNET_IDS
./deploy-databricks-adapter.ps1
```

Deploys/updates the adapter stack and prints the Databricks-side connection
values (`AdapterHost`, `OAuthClientId`, `OAuthTokenEndpoint`, `OAuthScope`)
plus the OAuth client secret (handle as a secret — don't paste it into
tickets/chat).

## Databricks-side setup

1. **Catalog → gear icon (top of the Catalog panel) → Connections → Create
   HTTP Connection** pointing at `AdapterHost` (leave the path blank/`/`),
   auth = OAuth M2M, using the Cognito `OAuthClientId`/secret/
   `OAuthTokenEndpoint`/`OAuthScope`.
2. On the model, model-provider, or MCP service page you want to govern,
   find the **Policies** tab (marked Beta) → **Add External Policy**,
   attached to the connection above, with `policy_config` set to the DLP
   profile(s) to enforce, e.g.:
   ```json
   {"profiles": ["Block SSN GenAI"]}
   ```
3. Start in **Log mode** to validate without blocking traffic, then switch
   to enforce once you've confirmed the expected ALLOW/DENY behavior.
   Allow ~60-90s for policy propagation after attaching/editing before
   testing.

## Known gotchas

- **`DLP_DLPAAS_FEATURE_ENABLE_OCR`** must be enabled on the Netskope
  backend per-tenant for image OCR to work at all (see above).
- **`x-netskope-generate-incidents`** must be set or DLP blocks won't
  appear in SkopeIT (see above) — the adapter sets this by default, but a
  hand-rolled DLPoD REST call elsewhere in your org might not.
- **`config.policy_config` may arrive as a JSON-encoded string, not an
  object.** Databricks documents it as an opaque pass-through it "never
  parses" — the adapter normalizes either shape (`as_obj()`), but if you're
  extending it, don't assume it's already parsed.
- **The model/tool payload shape varies** — a real request may use either
  the classic Chat Completions shape (`messages: [{role, content}]`) or the
  newer Responses API shape (`input: [{role, content: [{type, text}]}]`).
  The adapter handles both.
- **DLPoD sync `/inspections` only supports `verdict: summary`/`details`**,
  not `forensics` — that needs the async `/inspections/jobs` two-call flow,
  which doesn't fit Databricks' timeout budget and isn't used here.
- **OAuth M2M is the only supported auth method** for Databricks External
  Policies. API keys, Basic auth, and OAuth U2M are not supported. The
  adapter stack provisions Cognito specifically to satisfy this.
- **A plain Lambda Function URL (`AuthType: NONE`) may get a blanket 403**
  from the deploying AWS account/org — many enterprises block public,
  unauthenticated Function URLs at the account/org level. This adapter
  routes through API Gateway instead, which also gives a native JWT
  authorizer for the Cognito token.
- **`aws cloudformation deploy --tags` is unreliable when retagging** — the
  deploy script applies optional tags via a separate `update-stack
  --use-previous-template` call instead.
- **Databricks propagates policy changes through a config cache** — wait
  60-90 seconds after creating/attaching a policy before testing.
