# Noname/Akamai AWS Serverless Connector — Setup & Gotchas

**Originally deployed:** 2026-08-22 | **Connector stacks redeployed:** 2026-09-16 |
**Doc refreshed against live AWS:** 2026-09-18 | Region: us-east-2 | Account: 491489166083

> **Everything in this doc was re-verified against live AWS on 2026-09-18.** The
> connector stacks were torn down and redeployed on 2026-09-16, which renamed
> all three stacks and minted new resource suffixes. **Every ARN in the previous
> version of this doc is dead** — the old suffixes `-0aa5476ff309` and
> `-067c4e4bc2a7` no longer exist in this account. So is the old target log
> group `/aws/apigateway/mcropsey-lab-vampi`.

## Stacks (all CREATE_COMPLETE)

| Stack | Role | Deploy |
|---|---|---|
| `mcropsey-orchestrator-stack` | Scans org, configures resources, reports to Noname | Once, centralized account |
| `mcropsey-forwarder-stack` | Receives API GW logs via Kinesis, forwards to Noname | Once per region |
| `mcropsey-workload-stack` | Grants orchestrator cross-account access | Once per account |

All three were created 2026-09-16 and gained a `-stack` suffix; they were
previously `mcropsey-orchestrator` / `-forwarder` / `-workload`.

**None of these change when swapping the target app.** The connector stacks are
app-agnostic — they discover REST API Gateways by tag and wire up CloudWatch
subscription filters. Only the connection rule and the log group name change.

## Resource suffixes

The connector appends a per-stack random suffix to every resource. Learn the two
that matter and the rest follow:

| Component | Suffix | Stack |
|---|---|---|
| Orchestrator side | `02ab7fbdd39f` | `mcropsey-orchestrator-stack` |
| Forwarder side | `02f9f19d021f` | `mcropsey-forwarder-stack` |

## Key ARNs

Verified live 2026-09-18.

| | ARN |
|---|---|
| NonameConfiguratorFunctionArn | `arn:aws:lambda:us-east-2:491489166083:function:NonameConfiguratorOrchestrator-02ab7fbdd39f` |
| NonameProcessorFunctionArn | `arn:aws:lambda:us-east-2:491489166083:function:NonameConfiguratorProcessor-02ab7fbdd39f` |
| NonameScannerFunctionArn | `arn:aws:lambda:us-east-2:491489166083:function:NonameConfiguratorScanner-02ab7fbdd39f` |
| NonameReporterFunctionArn | `arn:aws:lambda:us-east-2:491489166083:function:NonameConfiguratorReporter-02ab7fbdd39f` |
| SensorRegistryKMSKeyArn | `arn:aws:kms:us-east-2:491489166083:key/d436a92c-b6ba-4ddb-a2fb-930f470ebf8c` |
| Kinesis destination | `arn:aws:logs:us-east-2:491489166083:destination:NonameKinesisCloudWatchLogsDestination-02f9f19d021f` |
| CloudWatchKinesisRole | `arn:aws:iam::491489166083:role/NonameCloudWatchKinesisRole-0ab2ef0fa13d` |
| Kinesis stream | `NonameKinesisDataStream-02f9f19d021f` |
| Sender Lambda | `NonameSender-02f9f19d021f` |
| ProcessQueue | `https://sqs.us-east-2.amazonaws.com/491489166083/NonameProcessQueue-02ab7fbdd39f` |
| ReportQueue | `https://sqs.us-east-2.amazonaws.com/491489166083/NonameReportQueue-02ab7fbdd39f` |

Note the `CloudWatchKinesisRole` suffix (`0ab2ef0fa13d`) does **not** match the
forwarder suffix. Read it off the live subscription filter rather than assuming.

## Connector Versions

| | Version |
|---|---|
| `NONAME_CONNECTOR_DEPLOYMENT_VERSION` | **6.0.2** (was 6.0.1 before the redeploy) |
| `CONNECTOR_CODE_VERSION` | `v3.71.0` |

Read them off any connector Lambda:

```bash
aws lambda get-function-configuration --region us-east-2 \
  --function-name NonameConfiguratorOrchestrator-02ab7fbdd39f \
  --query 'Environment.Variables.{deploy:NONAME_CONNECTOR_DEPLOYMENT_VERSION,code:CONNECTOR_CODE_VERSION}'
```

## Deploy Order

```
1. orchestrator.cfn.yaml  →  record NonameConfiguratorFunctionArn + SensorRegistryKMSKeyArn
2. forwarder.cfn.yaml     →  requires NonameConfiguratorFunctionArn
3. workload.cfn.yaml      →  requires NonameConfiguratorFunctionArn + SensorRegistryKMSKeyArn
```

---

## Target app: what the connector needs from it

The VAmPI stack must provide three things or discovery silently never completes.
All three are in `mcropsey-lab-vampi-apigw.yaml`:

1. **A REST API v1** (`AWS::ApiGateway::RestApi`) — gotcha 0.
2. **The marker tag** `inspected-by-noname-security` on the RestApi — gotcha 8.
3. **Execution logging enabled** on the stage via `MethodSettings` — gotcha 9.

And it must *not* provide a fourth: a customer-created access log group. See
gotcha 9.

---

## Checklist after a `--fresh` redeploy

A fresh stack gets a new API Gateway id, which changes the log group name, and a
new stack ARN.

- [ ] **Connection rule value is `mcropsey-aws-gw-vampi`** (tag key
      `aws:cloudformation:stack-name`). It used to be `mcropsey-lab`. Matching on
      stack *name* survives `--fresh`; matching on stack-id does not.
- [ ] **Confirm the RestApi carries `inspected-by-noname-security`.** Without it
      the API Security Server skips the API entirely, no matter what the
      connection rule says.
- [ ] **Confirm execution logging is on** for the `prod` stage
      (`loggingLevel: INFO`, `dataTraceEnabled: true`).
- [ ] **Confirm the subscription filter exists** on
      `API-Gateway-Execution-Logs_<newRestApiId>/prod`. The orchestrator creates
      it within a 5-minute cycle. Manual fallback in gotcha 4.
- [ ] **Do not create a custom access log group** and do not add
      `AccessLogSetting` to the stage. Both re-break discovery — gotcha 9.
- [ ] **Expect the old endpoints to age out of the Noname UI** rather than
      disappearing immediately.

---

## How Traffic Flows

```
Client → REST API GW (mcropsey-aws-gw-vampi-api, id 7wz0kp5wyb)
       → CloudWatch log group API-Gateway-Execution-Logs_7wz0kp5wyb/prod
         (created by AWS, access logging PATCHed in by the connector)
       → subscription filter "noname-filter"
       → Kinesis destination NonameKinesisCloudWatchLogsDestination-02f9f19d021f
       → Kinesis stream NonameKinesisDataStream-02f9f19d021f
       → Sender Lambda NonameSender-02f9f19d021f → Noname

Not captured (deliberate bypass, for debugging only):
  Client → EC2:5000 directly   (http://3.20.29.82:5000)
```

Single path, single log group. The crAPI build had two gateways plus a
CloudFront-to-EC2 bypass for MailHog's WebSocket; all of that is gone.

### The access log format is the connector's, not yours

The connector PATCHes the stage's `accessLogSettings` to its own delimited
format. Live value:

```
[NONAME]$context.requestId,$context.identity.sourceIp,$context.identity.caller,$context.identity.user,$context.requestTime,$context.httpMethod,$context.path,$context.status,$context.protocol,$context.responseLength,$context.domainName,$context.accountId[NONAME]
```

This shows up as CloudFormation drift on `VampiStage` and **that drift is
expected** — see the drift section in `mcropsey-lab-vampi-apigw.md`. Do not
"fix" it by redeploying an `AccessLogSetting`.

---

## Post-Deploy: Required UI Step

**Settings → Integrations → Traffic Sources → Edit Connection Rules**

> By default, Noname captures no traffic until rules are configured.

Select **Connect all resources** or define tag/resource-group rules. This triggers the
orchestrator to auto-configure matching API GW resources (create CloudWatch subscription
filters, etc.).

**Connection rule for the VAmPI stack:**
- Tag key: `aws:cloudformation:stack-name`
- Value: `mcropsey-aws-gw-vampi`

This is the recommended rule — it survives `--fresh` redeploys, which a stack-id
rule does not. If you prefer stack-id matching, pull the current ARN with:

```bash
aws cloudformation describe-stacks --stack-name mcropsey-aws-gw-vampi --region us-east-2 \
  --query 'Stacks[0].StackId' --output text
# arn:aws:cloudformation:us-east-2:491489166083:stack/mcropsey-aws-gw-vampi/5664b470-b126-11f1-afa9-0651ae3222a5
```

The template also tags the REST API with `Project: mcropsey-aws-gw` if you'd rather
match on a tag you control rather than a CloudFormation-generated one.

**A connection rule is necessary but not sufficient.** The rule decides what the
orchestrator *configures*; the `inspected-by-noname-security` tag decides what
the API Security Server *inspects*. You need both.

## EventBridge Schedule (v6.0.2)

The orchestrator runs on a 5-minute cycle via EventBridge. In v6 the Configurator was
split into separate Lambdas:

| Rule | Schedule |
|---|---|
| NonameOrchestratorEventBridgeRule-02ab7fbdd39f | rate(5 minutes) |
| NonameProcessorEventBridgeRule-02ab7fbdd39f | rate(5 minutes) |
| NonameReporterEventBridgeRule-02ab7fbdd39f | rate(5 minutes) |
| NonameScannerEventBridgeRule-02ab7fbdd39f | rate(5 minutes) |
| NonameCodeDeployerEventBridgeRule-02ab7fbdd39f | rate(10 minutes) |
| NonameSenderEventBridgeRule-02f9f19d021f | rate(10 minutes) |

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
groups automatically. The filter it creates is named **`noname-filter`** and carries a
long `[msg="*…"]` pattern that selects execution-log lines plus anything
`[NONAME]`-delimited — it is *not* an empty pattern. If you must recreate it by hand,
copy the live one rather than inventing it:

```bash
# read the live filter (name, destination, role, pattern) and reuse it verbatim
aws logs describe-subscription-filters \
  --log-group-name "API-Gateway-Execution-Logs_7wz0kp5wyb/prod" \
  --region us-east-2
```

**5. "Pending" after rules are set = normal delay.** Noname processes the initial traffic
batch before the status changes. Verify the pipeline is working (see Verification) before
assuming it's stuck.

**6. VAmPI generates less traffic volume than crAPI.** No browser, no SPA asset requests,
no background polling — only the calls you make. If Noname's endpoint discovery looks thin,
that's expected, not a pipeline fault. Drive volume with `./test-all-endpoints.sh --loop 5`.

**7. Orchestrator log messages explained:**
- `"Skipping account - previous scan cycle not yet complete"` — normal, previous scan still running
- `"Orchestrator should not run - skipping scheduled event processing due to run interval property"` — normal, run interval throttle
- `"Successfully enqueued scheduled scans for role"` with `sentCount: 5` — active scan cycle started ✅

**8. The `inspected-by-noname-security` tag is required, on the RestApi, with an
empty value.** APIs without this tag key are skipped by the API Security Server
regardless of connection rules. Three non-obvious details:

- The **value is ignored**, so it stays `""`.
- The **key must be non-empty**, or AWS rejects the entire tag set with
  `Member must have length greater than or equal to 1`.
- It must sit on the **RestApi**, not the Stage. Tagging only the stage does
  nothing.

```bash
aws apigateway get-rest-api --rest-api-id 7wz0kp5wyb --region us-east-2 --query 'tags'
# must include:  "inspected-by-noname-security": ""
```

**9. Do not give the stage a customer-created access log group.** This is the
one that cost real time, and it is why the template deliberately contains *no*
`AWS::Logs::LogGroup` and *no* `AccessLogSetting`.

*Symptom:* the Processor fails on operation step 2 for `api-gateway`, retries
every ~15 minutes forever, and the resource never comes online — while the
connector itself keeps reporting healthy. The error:

```
1 validation error detected: Value at 'tags' failed to satisfy constraint:
Member must have length greater than or equal to 1
```

*Root cause:* the connector calls CloudWatch Logs with an **empty tag map**.
Confirmed live — the orchestrator stack's `CustomTags` parameter is `{}`, and
the Processor Lambda carries `CUSTOM_TAGS={}`:

```bash
aws lambda get-function-configuration --region us-east-2 \
  --function-name NonameConfiguratorProcessor-02ab7fbdd39f \
  --query 'Environment.Variables.CUSTOM_TAGS'     # -> "{}"
```

`logs:TagResource` with `tags:{}` reproduces that string byte for byte;
`apigateway:TagResource` with `tags:{}` returns a *different* error — so the
failing call is against CloudWatch Logs, not API Gateway.

*Why the log group matters:* the connector only reaches that failing call when
it has to **create** the log group. If
`API-Gateway-Execution-Logs_<restApiId>/<stageName>` already exists, it skips
`CreateLogGroup` and goes straight to attaching `noname-filter`.

*The fix (applied 2026-09-16):* turn on **execution logging**, which makes API
Gateway auto-create that log group.

```yaml
MethodSettings:
  - ResourcePath: "/*"
    HttpMethod: "*"
    LoggingLevel: INFO
    DataTraceEnabled: true
```

This is why every working stage in this account has `loggingLevel INFO` +
`dataTrace true`. Verify:

```bash
aws apigateway get-stage --rest-api-id 7wz0kp5wyb --stage-name prod --region us-east-2 \
  --query 'methodSettings'
```

*The other possible fix, deliberately not taken:* set `CustomTags` on the
orchestrator stack to a non-empty map so the connector never sends `tags:{}`.
That is a cleaner root-cause fix, but the orchestrator is shared infrastructure
in a multi-tenant account — changing it affects every other lab here. Likewise
leave `CloudWatchRetentionPolicyOverride=false`; flipping it would let the
connector rewrite retention on *other people's* existing log groups.

> An earlier note in the template claimed the orchestrator "predates the
> `CustomTags` parameter, so the Lambdas have no `CUSTOM_TAGS` env var at all."
> That was true of the 2026-08-21 deployment but is **not** true of the current
> one — the parameter exists and is set to the empty map `{}`, which is exactly
> what triggers the failure. The `MethodSettings` workaround is unaffected.

---

## Verification

```bash
LOG_GROUP="API-Gateway-Execution-Logs_7wz0kp5wyb/prod"

# 1. Subscription filter exists on the API GW execution log group
aws logs describe-subscription-filters \
  --log-group-name "$LOG_GROUP" \
  --region us-east-2 \
  --query 'subscriptionFilters[].[filterName,destinationArn]' --output text
# want: noname-filter  arn:...:destination:NonameKinesisCloudWatchLogsDestination-02f9f19d021f

# 2. Kinesis receiving records (should be non-zero when traffic is flowing)
aws cloudwatch get-metric-statistics \
  --namespace AWS/Kinesis \
  --metric-name IncomingRecords \
  --dimensions Name=StreamName,Value=NonameKinesisDataStream-02f9f19d021f \
  --start-time $(date -u -v-10M +%Y-%m-%dT%H:%M:%SZ) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%SZ) \
  --period 600 --statistics Sum --region us-east-2 \
  --query 'Datapoints[*].[Timestamp,Sum]' --output table

# 3. Sender Lambda invocations (should be non-zero)
aws cloudwatch get-metric-statistics \
  --namespace AWS/Lambda \
  --metric-name Invocations \
  --dimensions Name=FunctionName,Value=NonameSender-02f9f19d021f \
  --start-time $(date -u -v-15M +%Y-%m-%dT%H:%M:%SZ) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%SZ) \
  --period 900 --statistics Sum --region us-east-2 \
  --query 'Datapoints[*].[Timestamp,Sum]' --output table

# 4. Recent Orchestrator logs
aws logs filter-log-events \
  --log-group-name /aws/lambda/NonameConfiguratorOrchestrator-02ab7fbdd39f \
  --start-time $(date -u -v-30M +%s000) \
  --region us-east-2 \
  --query 'events[*].message' --output text

# 5. Processor logs — where the empty-tag failure in gotcha 9 shows up
aws logs filter-log-events \
  --log-group-name /aws/lambda/NonameConfiguratorProcessor-02ab7fbdd39f \
  --start-time $(date -u -v-30M +%s000) \
  --region us-east-2 \
  --filter-pattern '"failed to satisfy constraint"' \
  --query 'events[*].message' --output text
# want: no output
```

All of 1-3 returning data = pipeline is healthy. "Pending" in the Noname UI after this
point is Noname-side processing, not an AWS issue.

### Generate traffic to verify end to end

```bash
cd ~/Downloads/aws-api-gw-vampi
./test-all-endpoints.sh --loop 5
```

The script resolves `BASE_URL` from the stack outputs, so it keeps working after
a `--fresh` redeploy. Then re-run checks 1-3; records should appear in Kinesis
within a minute or two.

---

## Orphaned resource to be aware of

`/aws/apigateway/mcropsey-aws-gw-vampi` still exists (~353 KB, 14-day retention).
It is the log group the *deployed* template creates, it has **no subscription
filter**, and nothing writes to it any more — the connector moved access logging
to `API-Gateway-Execution-Logs_7wz0kp5wyb/prod`. It is still a stack resource, so
it will be removed on the next successful deploy of the working-tree template, or
on stack delete. Harmless either way; just don't mistake it for the live log
group when debugging.
