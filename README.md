# Netskope DLP On Demand ↔ Databricks Unity AI Gateway

Wire an existing **Netskope DLP On Demand (DLPoD)** appliance into the
**Databricks Unity AI Gateway External Policy** framework, so Databricks
enforces Netskope's DLP verdicts — including OCR-based DLP on images — on
live model and tool traffic.

> **Prerequisite:** this repo assumes you already have a DLPoD appliance
> deployed and tethered to your Netskope tenant, reachable via an internal
> ALB. It deploys only the Databricks-side adapter — not the appliance
> itself. See [`NOTICE`](NOTICE).

📄 **See [`Netskope-DLPoD-Databricks-Solutions-Guide.docx`](Netskope-DLPoD-Databricks-Solutions-Guide.docx)**
for the full, illustrated, step-by-step deployment guide (architecture
diagram, prerequisites, every step, troubleshooting, and the full API
reference). This README is the quick-reference version.

---

## What gets deployed

One CloudFormation stack, **the Databricks adapter**
(`templates/databricks-adapter.yaml`) — a small serverless Lambda that
translates between the Databricks External Policy contract and DLPoD's sync
content-inspection API, fronted by API Gateway and secured with Cognito
OAuth2 client-credentials (the only auth method Databricks' contract
supports).

```
Databricks Unity AI Gateway (External Policy)
        │  OAuth M2M bearer token
        ▼
API Gateway + Cognito  →  Lambda (translation adapter)
        │  VPC-internal HTTPS, no NAT needed
        ▼
Internal ALB  →  DLPoD appliance  →  Verdict
```

`docs/databricks-adapter.md` has the adapter's full technical reference
(request/response contract, event-type handling, troubleshooting).

### Text and image (OCR) DLP

The adapter inspects both prompt/response **text** and **image** content
(a screenshot pasted into chat, for example) against your configured DLP
profiles. Image inspection uses DLPoD's OCR capability — see
`docs/databricks-adapter.md` for the one Netskope-tenant-side prerequisite
this needs.

---

## Prerequisites

| Requirement | Notes |
|-------------|-------|
| **Existing DLPoD appliance** | Already deployed, tethered to your Netskope tenant, reachable via an internal ALB. |
| **DLP profile(s) configured** | At least one DLP profile in your Netskope tenant to enforce (custom or predefined — call `GET /inspections/profiles` on the appliance to list them). |
| **`DLP_DLPAAS_FEATURE_ENABLE_OCR` enabled** | Only needed if you want image/OCR-based DLP — ask your Netskope account team to enable this backend feature flag for your tenant. |
| **Existing VPC** | Any subnet in the same VPC as the DLPoD appliance's internal ALB works for the Lambda adapter (no NAT/internet needed). |
| **Databricks workspace** | Unity Catalog enabled, and the External Policies (Direct HTTP API) feature enabled — confirm with your Databricks account team. |
| **Databricks permissions** | `CREATE CONNECTION` (or metastore admin) to create the UC HTTP Connection; `MANAGE` on the schema of the service you'll govern. |
| **AWS CLI** | Configured for the target account/region. |

---

## Quick start

```powershell
cp .env.example .env      # fill in VPC_ID, LAMBDA_SUBNET_IDS
./deploy-databricks-adapter.ps1
```

Then configure Databricks — create the UC HTTP Connection with the printed
outputs, then attach an External Policy (see the solutions guide, or
`docs/databricks-adapter.md`).

Prefer raw `aws cloudformation deploy`? The template takes standard
`--parameter-overrides` — see its `Parameters` section, or the solutions
guide's parameter table.

---

## Parameters (`templates/databricks-adapter.yaml`)

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `VpcId` | ✅ | — | Same VPC as the DLPoD appliance's internal ALB. |
| `LambdaSubnetIds` | ✅ | — | Any subnet in that VPC (no NAT/internet needed). |
| `DlpEvaluationUrl` | | `https://dlp.dlpod.internal/inspections` | Full URL of the DLPoD sync content inspection API. |
| `CertParameterName` | | `/netskope-dlpod/dlpod-cert` | SSM parameter holding the ALB's cert PEM. |
| `DefaultProfiles` | | *(blank)* | Optional fallback DLP profile name(s), comma-separated. |
| `GenerateIncidents` | | `true` | Whether DLPoD posts alerts/incidents to SkopeIT for matches. |

---

## After deployment

1. Confirm the stack deployed cleanly and note the outputs (`AdapterHost`,
   `OAuthClientId`, `OAuthTokenEndpoint`, `OAuthScope`, `UserPoolId`).
2. Create a UC HTTP Connection in Databricks using those values.
3. Attach an External Policy to the model/provider/MCP service you want
   governed, with `policy_config` set to your DLP profile(s), e.g.
   `{"profiles": ["Block SSN GenAI"]}`.
4. Start in **Log mode**, validate with a benign prompt and a
   policy-violating prompt, then switch to enforce.
5. Check SkopeIT for the corresponding DLP alert (Application:
   **DatabricksAIGateway**) to confirm end-to-end visibility.

### Stack outputs

`AdapterHost`, `OAuthClientId`, `OAuthTokenEndpoint`, `OAuthScope`,
`UserPoolId` (used to retrieve the Client Secret), `AdapterFunctionArn`.

---

## Teardown

```bash
aws cloudformation delete-stack --stack-name netskope-dlpod-databricks-adapter --region us-west-1
```

---

## Repository layout

```
templates/
  databricks-adapter.yaml      The Databricks adapter CloudFormation template
deploy-databricks-adapter.ps1  Deploys the adapter
.env.example                   Copy to .env and fill in
docs/
  databricks-adapter.md        Adapter technical reference + troubleshooting
  dlpod-databricks-flow.excalidraw   Editable diagram of the call flow
Netskope-DLPoD-Databricks-Solutions-Guide.docx   Full illustrated deployment guide
CLAUDE.md                      Guidance for Claude Code working in this repo
NOTICE / LICENSE                Apache-2.0
```

---

## Notes & gotchas

- **Databricks OAuth M2M is the only supported auth method** for External
  Policies — the adapter stack provisions Cognito specifically for this.
- **`config.policy_config` may arrive as a string or an object** — the
  adapter normalizes either shape.
- **OCR needs a Netskope-side feature flag** (`DLP_DLPAAS_FEATURE_ENABLE_OCR`)
  and **SkopeIT alerting needs the `x-netskope-generate-incidents` header**
  (the adapter sets this by default) — see `docs/databricks-adapter.md` for
  both.
- **`aws cloudformation deploy --tags` is unreliable on retagging** — the
  deploy script applies optional tags via a separate `update-stack
  --use-previous-template` call instead.

## License

Apache License 2.0 — see [`LICENSE`](LICENSE) and [`NOTICE`](NOTICE).
