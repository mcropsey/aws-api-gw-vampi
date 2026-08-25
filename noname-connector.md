# Noname/Akamai AWS Serverless Connector — Setup & Gotchas
**Deployed:** 2026-08-22 | **Updated for VAmPI:** 2026-08-25 | Region: us-east-2 | Account: 491489166083

## Stacks (all CREATE_COMPLETE)

| Stack | Role | Deploy |
|---|---|---|
| `mcropsey-orchestrator` | Scans org, configures resources, reports to Noname | Once, centralized account |
| `mcropsey-forwarder` | Receives API GW logs via Kinesis, forwards to Noname | Once per region |
| `mcropsey-workload` | Grants orchestrator cross-account access | Once per account |

**None of these change when swapping the target app from crAPI to VAmPI.** The connector
stacks are app-agnostic — they discover REST API Gateways by tag and wire up CloudWatch
subscription filters. Only the connection rule and the log group name change.

## Key ARNs

| | ARN |
|---|---|
| NonameConfiguratorFunctionArn | `arn:aws:lambda:us-east-2:491489166083:function:NonameConfiguratorOrchestrator-0aa5476ff309` |
| SensorRegistryKMSKeyArn | `arn:aws:kms:us-east-2:491489166083:key/af16e197-171d-4888-8b0e-2b1e1b58cd13` |
| Kinesis destination | `arn:aws:logs:us-east-2:491489166083:destination:NonameKinesisCloudWatchLogsDestination-067c4e4bc2a7` |
| CloudWatchKinesisRole | `arn:aws:iam::491489166083:role/NonameCloudWatchKinesisRole-0aa6765bb09f` |

## Connector Stack Versions

| Stack | Version |
|---|---|
| `mcropsey-*` | 6.0.1 |
| `dustin-*` | 5.0.2 (reference — deployed earlier) |

## Deploy Order

```
1. orchestrator.cfn.yaml  →  record NonameConfiguratorFunctionArn + SensorRegistryKMSKeyArn
2. forwarder.cfn.yaml     →  requires NonameConfiguratorFunctionArn
3. workload.cfn.yaml      →  requires NonameConfiguratorFunctionArn + SensorRegistryKMSKeyArn
```

---

## Migration checklist: crAPI → VAmPI

Work through this after running `./deploy-vampi.sh --fresh`.

- [ ] **Update the connection rule stack-id.** A fresh stack gets a new stack ARN. The
      deploy script prints it. If you match on `aws:cloudformation:stack-name` = `mcropsey-lab`
      instead, no change is needed — the stack name is unchanged.
- [ ] **Confirm the new log group has a subscription filter** — `/aws/apigateway/mcropsey-lab-vampi`.
      The orchestrator creates it within a 5-minute cycle. Manual fallback below.
- [ ] **Expect the old crAPI/MailHog endpoints to age out of the Noname UI.** The
      `/aws/apigateway/mcropsey-lab-crapi` and `/aws/apigateway/mcropsey-lab-mailhog`
      log groups are stack resources and were deleted with the stack, so their filters
      went with them. The discovered endpoints linger in Noname until it ages them out.
- [ ] **Re-check coverage expectations.** Under crAPI, MailHog web UI traffic bypassed the
      gateway and was invisible to Noname. Under VAmPI there is no bypass path except the
      direct `EIP:5000` URL — if you want 100% capture, always test against the `/prod` URL.

---

## How Traffic Flows

```
VAmPI:
  Client → REST API GW (mcropsey-lab-vampi-api)
         → CloudWatch log group (/aws/apigateway/mcropsey-lab-vampi)
         → subscription filter → Kinesis stream (NonameKinesisDataStream-067c4e4bc2a7)
         → Sender Lambda (NonameSender-067c4e4bc2a7) → Noname

Not captured (deliberate bypass, for debugging only):
  Client → EC2:5000 directly
```

Single path, single log group. The crAPI build had two gateways plus a CloudFront-to-EC2
bypass for MailHog's WebSocket; all of that is gone.

## Post-Deploy: Required UI Step

**Settings → Integrations → Traffic Sources → Edit Connection Rules**

> By default, Noname captures no traffic until rules are configured.

Select **Connect all resources** or define tag/resource-group rules. This triggers the
orchestrator to auto-configure matching API GW resources (create CloudWatch subscription
filters, etc.).

**Connection rule for the VAmPI stack:**
- Tag key: `aws:cloudformation:stack-name`
- Value: `mcropsey-lab`

This is the recommended rule now — it survives `--fresh` redeploys, which the stack-id
rule does not. If you prefer stack-id matching, pull the current ARN with:

```bash
aws cloudformation describe-stacks --stack-name mcropsey-lab --region us-east-2 \
  --query 'Stacks[0].StackId' --output text
```

The template also tags the REST API with `Project: mcropsey-lab` if you'd rather match on
a tag you control rather than a CloudFormation-generated one.

## EventBridge Schedule (v6.0.1)

The orchestrator runs on a 5-minute cycle via EventBridge. In v6 the Configurator was
split into separate Lambdas:

| Rule | Schedule |
|---|---|
| NonameOrchestratorEventBridgeRule-0aa5476ff309 | rate(5 minutes) |
| NonameProcessorEventBridgeRule-0aa5476ff309 | rate(5 minutes) |
| NonameReporterEventBridgeRule-0aa5476ff309 | rate(5 minutes) |
| NonameScannerEventBridgeRule-0aa5476ff309 | rate(5 minutes) |
| NonameCodeDeployerEventBridgeRule-0aa5476ff309 | rate(10 minutes) |
| NonameSenderEventBridgeRule-067c4e4bc2a7 | rate(10 minutes) |

## Gotchas

**0. API Gateway MUST be REST API (v1), not HTTP API (v2).** The Noname Configurator only
discovers `AWS::ApiGateway::RestApi` resources. `AWS::ApiGatewayV2::Api` (HTTP API) is
silently ignored regardless of tags. WebSocket API type is also unsupported. **Still true
for VAmPI** — this is a connector limitation, not an app limitation.

**1. ~~REST API v1 `/prod` stage breaks SPAs.~~ — no longer applicable.** This was the
reason for the crAPI CloudFront distribution: the crAPI frontend used absolute asset paths
(`/static/js/...`) that resolved without the `/prod` prefix and 403'd. VAmPI is JSON-only
with no compiled frontend, so the stage prefix is harmless and CloudFront was removed.
*Keep this note* — the problem returns immediately if you ever put an SPA-based target
(crAPI, Juice Shop, DVGA) behind a REST API GW again.

**2. ~~REST API GW cannot proxy WebSocket.~~ — no longer applicable.** This forced the
MailHog CloudFront bypass. VAmPI has no WebSocket, so nothing bypasses the gateway now.
Same caveat as above: still true of the gateway, just no longer relevant to this target.

**2a. Swagger UI at `/ui/` is partly broken behind the gateway.** Connexion points the UI
at an absolute `/openapi.json`, which 403s without the `/prod` prefix. The UI shell renders
but "Try it out" fails. Use the direct `EIP:5000/ui/` URL, or import the OpenAPI spec.
This is cosmetic — it does not affect API traffic capture at all.

**3. Forwarder requires `NonameConfiguratorFunctionArn`** — mandatory parameter, same as
workload. Easy to miss if following older docs that only showed it for workload.

**4. Subscription filter is automatic — but only after connection rules are set.** The
orchestrator creates the CloudWatch → Kinesis subscription filter on matching API GW log
groups automatically. If you set rules and the filter still isn't there after a full cycle,
create it manually:

```bash
aws logs put-subscription-filter \
  --log-group-name /aws/apigateway/mcropsey-lab-vampi \
  --filter-name noname-forwarder \
  --filter-pattern "" \
  --destination-arn "arn:aws:logs:us-east-2:491489166083:destination:NonameKinesisCloudWatchLogsDestination-067c4e4bc2a7" \
  --role-arn "arn:aws:iam::491489166083:role/NonameCloudWatchKinesisRole-0aa6765bb09f" \
  --region us-east-2
```

**5. "Pending" after rules are set = normal delay.** Noname processes the initial traffic
batch before the status changes. Verify the pipeline is working (see Verification) before
assuming it's stuck.

**6. VAmPI generates less traffic volume than crAPI.** No browser, no SPA asset requests,
no background polling — only the calls you make. If Noname's endpoint discovery looks thin,
that's expected, not a pipeline fault. Drive volume with the VAmPI Postman collection or a
loop over the endpoint table in `mcropsey-lab-vampi-apigw.md`.

**7. Orchestrator log messages explained:**
- `"Skipping account - previous scan cycle not yet complete"` — normal, previous scan still running
- `"Orchestrator should not run - skipping scheduled event processing due to run interval property"` — normal, run interval throttle
- `"Successfully enqueued scheduled scans for role"` with `sentCount: 5` — active scan cycle started ✅

## Verification

```bash
# 1. Subscription filter exists on the VAmPI API GW log group
aws logs describe-subscription-filters \
  --log-group-name /aws/apigateway/mcropsey-lab-vampi \
  --region us-east-2

# 2. Kinesis receiving records (should be non-zero when traffic is flowing)
aws cloudwatch get-metric-statistics \
  --namespace AWS/Kinesis \
  --metric-name IncomingRecords \
  --dimensions Name=StreamName,Value=NonameKinesisDataStream-067c4e4bc2a7 \
  --start-time $(date -u -v-10M +%Y-%m-%dT%H:%M:%SZ) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%SZ) \
  --period 600 --statistics Sum --region us-east-2 \
  --query 'Datapoints[*].[Timestamp,Sum]' --output table

# 3. Sender Lambda invocations (should be non-zero)
aws cloudwatch get-metric-statistics \
  --namespace AWS/Lambda \
  --metric-name Invocations \
  --dimensions Name=FunctionName,Value=NonameSender-067c4e4bc2a7 \
  --start-time $(date -u -v-15M +%Y-%m-%dT%H:%M:%SZ) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%SZ) \
  --period 900 --statistics Sum --region us-east-2 \
  --query 'Datapoints[*].[Timestamp,Sum]' --output table

# 4. Recent Orchestrator logs
aws logs filter-log-events \
  --log-group-name /aws/lambda/NonameConfiguratorOrchestrator-0aa5476ff309 \
  --start-time $(date -u -v-30M +%s000) \
  --region us-east-2 \
  --query 'events[*].message' --output text
```

All of 1-3 returning data = pipeline is healthy. "Pending" in the Noname UI after this
point is Noname-side processing, not an AWS issue.

### Generate traffic to verify end to end

```bash
BASE_URL="https://ppcc9onu1h.execute-api.us-east-2.amazonaws.com/prod"

for i in $(seq 1 25); do
  curl -s "$BASE_URL/users/v1" > /dev/null
  curl -s "$BASE_URL/users/v1/_debug" > /dev/null
  curl -s -X POST "$BASE_URL/users/v1/login" \
    -H "Content-Type: application/json" \
    -d '{"username":"name1","password":"pass1"}' > /dev/null
  sleep 1
done
```

Then re-run checks 1-3. Records should appear in Kinesis within a minute or two.
