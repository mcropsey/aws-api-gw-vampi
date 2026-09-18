# mcropsey-aws-gw — VAmPI + API Gateway

**Converted from crAPI:** 2026-08-25 | **Renamed + redeployed:** 2026-09-15 |
**Doc refreshed against live AWS:** 2026-09-18 | Region: us-east-2 | Stack: `mcropsey-aws-gw-vampi`

> **The stack was renamed.** It used to be `mcropsey-lab`; it is now
> `mcropsey-aws-gw-vampi`, and every resource name derives from the `Prefix`
> parameter (`mcropsey-aws-gw`). The old name, the old API Gateway id
> `ppcc9onu1h` and the old EIP `3.135.133.6` are all dead — they appeared
> throughout the previous version of this doc.
>
> **Twin environment:** the same VAmPI fronted by an F5 BIG-IP instead of an API
> Gateway lives in `../aws-f5-vampi` (prefix `mcropsey-f5`, VPC `10.0.0.0/16`).
> The two share nothing: separate VPCs, stacks, key pairs and outputs. Either
> can be torn down without touching the other.

> **After any redeploy**, refresh live values:
> ```bash
> aws cloudformation describe-stacks --stack-name mcropsey-aws-gw-vampi --region us-east-2 \
>   --query 'Stacks[0].Outputs[*].[OutputKey,OutputValue]' --output table
> ```
> There are no CloudFront distributions in this stack. The API GW id changes on
> `--fresh` redeploy — update Live Values and the Noname connection rule.

---

## ⚠ Known drift: the committed template is not what is running

Verified 2026-09-18 with `aws cloudformation detect-stack-drift`. The live stack
was created 2026-09-15 and **has never been updated**, but the stage
configuration has been changed out of band since. Two things follow:

**1. The Noname connector has overwritten the stage's access logging.** Drift on
`VampiStage`:

| Property | Template expects | Actually live |
|---|---|---|
| `AccessLogSetting/DestinationArn` | `…log-group:/aws/apigateway/mcropsey-aws-gw-vampi:*` | `…log-group:API-Gateway-Execution-Logs_7wz0kp5wyb/prod` |
| `AccessLogSetting/Format` | the crAPI JSON format | `[NONAME]$context.requestId,…[NONAME]` |

This is correct and intended — see `noname-connector.md`. The connector owns
access logging end to end.

**2. `mcropsey-lab-vampi-apigw.yaml` has uncommitted edits that encode the fix
but have not been deployed.** The working tree removes `VampiApiLogGroup` and
the `AccessLogSetting`, and adds the `MethodSettings` block that actually made
the connector work. The deployed stack still contains `VampiApiLogGroup`
(`/aws/apigateway/mcropsey-aws-gw-vampi`, `IN_SYNC`, ~353 KB, **no subscription
filter — it receives nothing**).

**Consequence, and the reason this section exists:** running `./deploy-vampi.sh`
against the *committed* template would reset `AccessLogSetting` back to the
custom log group and re-break connector discovery. Running it against the
*working-tree* template converges everything correctly. Deploy the working tree,
or don't deploy at all.

---

## Live Values

Verified against the live stack 2026-09-18.

| | URL / Value |
|---|---|
| **VAmPI API** (BASE_URL) | `https://7wz0kp5wyb.execute-api.us-east-2.amazonaws.com/prod` |
| **Swagger UI** (direct only — see note) | `http://3.20.29.82:5000/ui/` |
| **VAmPI direct** (bypasses GW) | `http://3.20.29.82:5000` |
| **Elastic IP** | `3.20.29.82` |
| **REST API GW id** | `7wz0kp5wyb` |
| **REST API GW name** | `mcropsey-aws-gw-vampi-api` |
| **Prefix** | `mcropsey-aws-gw` |
| **SSH** | `ssh -i ~/.ssh/mcropsey-lab-key.pem ec2-user@3.20.29.82` |
| **Access log group** | `API-Gateway-Execution-Logs_7wz0kp5wyb/prod` (connector-owned) |
| **Noname stack-id** | `arn:aws:cloudformation:us-east-2:491489166083:stack/mcropsey-aws-gw-vampi/5664b470-b126-11f1-afa9-0651ae3222a5` |
| **Noname stack-name tag** | `mcropsey-aws-gw-vampi` |

Smoke-tested 2026-09-18: `/`, `/users/v1`, `/books/v1` all return `200` through
the gateway, and `http://3.20.29.82:5000/` returns `200` directly.

> **Don't hand-copy these into scripts.** `test-all-endpoints.sh` now resolves
> `BASE_URL` and `EIP` from the stack outputs at runtime, so it survives a
> `--fresh` redeploy. Override with `BASE_URL=… EIP=… ./test-all-endpoints.sh`
> if you need to point it elsewhere.

---

## What changed from the crAPI build

| Removed | Why it's no longer needed |
|---|---|
| CloudFront distribution for crAPI | VAmPI has no compiled SPA. Nothing requests `/static/js/...`, so the `/prod` stage prefix breaks nothing. |
| CloudFront distribution for MailHog | VAmPI sends no email. No MailHog, no WebSocket, no upgrade problem. |
| MailHog REST API GW + log group | Same. |
| Port 8025 in the security group | Same. |
| mongo / postgres / chromadb / 4 crAPI microservices | VAmPI is one 41 MB Flask container with SQLite. |
| `t3.large` / 30 GB | Downsized to `t3.small` / 20 GB. |

**Net effect:** 2 CloudFront distributions, 1 API Gateway, 1 log group, and ~9 containers
removed. One API Gateway remains, and **every request to BASE_URL is Noname-visible** —
the crAPI build had MailHog web UI traffic bypassing the gateway.

## What changed at the 2026-09-15 rename

| Change | Detail |
|---|---|
| `Prefix` parameter added | Default `mcropsey-aws-gw`, pattern `^[a-z][a-z0-9-]{1,30}$`. Every resource name and `Name` tag is now `!Sub "${Prefix}-…"`. |
| Stack renamed | `mcropsey-lab` → `mcropsey-aws-gw-vampi` |
| EC2 `Name` tag | `mcropsey-lab-instance` → `mcropsey-aws-gw-vampi` |
| AMI no longer hardcoded | Was `ami-0b4624933067d393a`. Now an `AWS::SSM::Parameter::Value<AWS::EC2::Image::Id>` pointing at `/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64`, so the image never goes stale. Currently resolves to `ami-09f2f3eeb95b394f2`. |
| `SSHCommand` output | Now derives the key filename from `${KeyPairName}` instead of hardcoding it. |
| Noname marker tag added | `inspected-by-noname-security` on the RestApi — **required**, see `noname-connector.md`. |
| Access logging handed to the connector | `VampiApiLogGroup` + `AccessLogSetting` removed; `MethodSettings` added. See the drift section above. |

The `Prefix` pattern forbids a trailing hyphen and caps at 31 characters; a
value like `MyLab` or `mcropsey-` is rejected at deploy time rather than
producing half-renamed resources.

---

## Architecture

```
                    ┌─────────────────────────────────────────────────────┐
                    │  mcropsey-aws-gw-vampi CloudFormation Stack         │
                    │                                                     │
You (HTTPS) ──────► │  REST API GW: mcropsey-aws-gw-vampi-api (7wz0kp5wyb)│
                    │    /prod stage → ANY / + ANY /{proxy+}              │
                    │    tag: inspected-by-noname-security                │
                    │    execution logging INFO + dataTrace (required)    │
                    │    access logs → API-Gateway-Execution-Logs_<id>/prod│
                    │      └──► subscription filter "noname-filter"       │
                    │           → Kinesis → Noname                        │
                    │    └──► EC2 EIP:5000 → VAmPI container              │
                    │                                                     │
                    │  EC2 t3.small AL2023 @ 3.20.29.82                   │
                    │    Docker Compose /opt/vampi                        │
                    │    └─ erev0s/vampi:latest → :5000 (SQLite, in-container)
                    │    └─ mcropsey-aws-gw-vpc 10.2.0.0/16               │
                    └─────────────────────────────────────────────────────┘
```

**Key decisions:**

- **REST API v1 (not HTTP API v2)** — unchanged from the crAPI build. The Noname
  connector only discovers `AWS::ApiGateway::RestApi`. HTTP API v2 is invisible to
  Noname regardless of tags.
- **No CloudFront** — VAmPI returns `application/json` for every endpoint. No SPA
  bundle, no absolute asset paths, no `BinaryMediaTypes` configuration, no WebSocket.
  The `/prod` stage prefix is simply part of the base URL and clients don't care.
- **DB seeded automatically at boot** — VAmPI ships with an empty database and throws
  SQLAlchemy errors until `/createdb` is called once. UserData does this with a retry
  loop. Re-run any time; it's idempotent (it drops and repopulates).
- **`vulnerable` is a stack parameter** — `./deploy-vampi.sh --secure` redeploys the
  identical API surface with the vulnerabilities patched. Useful for measuring Noname
  false positives against a known-good baseline.
- **Port 5000 open to `0.0.0.0/0`** — required because API GW integrations originate
  from non-static AWS IPs. SSH (22) is restricted to `AllowedSSHCIDR`, which
  `deploy-vampi.sh` pins to your workstation's `/32` at deploy time — so SSH stops
  working when your public IP changes, and the fix is to re-run the deploy script.
- **Execution logging is deliberately on** (`MethodSettings` → `LoggingLevel: INFO`,
  `DataTraceEnabled: true`). This is not for debugging — the connector depends on it.
  See `noname-connector.md`. `DataTraceEnabled` logs full request/response bodies, so
  treat that log group as sensitive; it is fine here because VAmPI holds only dummy data.

### Swagger UI caveat

`/ui/` loads its own assets relatively and will render behind the gateway, but Connexion
points the UI at an **absolute** `/openapi.json`. The browser requests that at the domain
root, missing `/prod`, and gets a 403 — so "Try it out" won't work through the gateway.

This is cosmetic and has three workarounds, in order of preference:

1. Use the direct EIP URL: `http://3.20.29.82:5000/ui/`
2. Import `openapi_specs/openapi3.yml` from the VAmPI repo into Postman or Noname
   and set the server URL to your `/prod` base URL.
3. Ignore it — everything in Quick Test below works fine with curl.

---

## Deploy / Redeploy

```bash
cd ~/Downloads/aws-api-gw-vampi

./deploy-vampi.sh            # deploy or update in place
./deploy-vampi.sh --fresh    # tear down completely and redeploy from scratch
./deploy-vampi.sh --secure   # deploy with vulnerable=0 (patched baseline)
```

Read the drift section at the top of this doc before deploying. The script
passes `Prefix`, `KeyPairName`, `AllowedSSHCIDR` and `VampiVulnerable` as
parameter overrides and prints the resolved prefix, region, stack and key pair
before it starts.

**Timing after `--fresh`:**
- CFN stack creates: ~3 min (no CloudFront — this is the big win)
- VAmPI image pulls + starts: ~1-2 min
- Total before fully usable: **~5-7 min** (was ~25-30 min)

The deploy script polls the API GW URL and runs a smoke test automatically, so you'll
know it's live before it exits.

**After a `--fresh` redeploy the API GW id changes**, which means a new log group
name (`API-Gateway-Execution-Logs_<newid>/prod`) and a new stack ARN. Work
through the checklist in `noname-connector.md`.

**Prerequisites (one-time):** Key pair `mcropsey-lab-key` must exist in AWS us-east-2
with `~/.ssh/mcropsey-lab-key.pem` locally. (The key pair kept its original name
through the rename — it is shared with nothing else and renaming it would have
forced a fresh instance.) AWS-generated keys break macOS OpenSSH 10+ —
generate locally and import:
```bash
ssh-keygen -t ed25519 -f ~/.ssh/mcropsey-lab-key -N ""
mv ~/.ssh/mcropsey-lab-key ~/.ssh/mcropsey-lab-key.pem && chmod 400 ~/.ssh/mcropsey-lab-key.pem
aws ec2 import-key-pair --key-name mcropsey-lab-key \
  --public-key-material fileb://~/.ssh/mcropsey-lab-key.pub --region us-east-2
```

---

## Stop / Start (cost saving)

EIP stays assigned — no stack update needed after restart. The container restarts
automatically (`restart: always`).

**Important:** VAmPI's SQLite DB lives inside the container filesystem. It survives a
restart, but if you ever recreate the container, hit `/createdb` again.

```bash
INSTANCE_ID=$(aws ec2 describe-instances --region us-east-2 \
  --filters "Name=tag:Name,Values=mcropsey-aws-gw-vampi" \
  --query "Reservations[0].Instances[0].InstanceId" --output text)

aws ec2 stop-instances --region us-east-2 --instance-ids "$INSTANCE_ID"
# or
aws ec2 start-instances --region us-east-2 --instance-ids "$INSTANCE_ID"
```

---

## Tear Down

```bash
aws cloudformation delete-stack --stack-name mcropsey-aws-gw-vampi --region us-east-2
aws cloudformation wait stack-delete-complete --stack-name mcropsey-aws-gw-vampi --region us-east-2
```

Faster than the crAPI teardown — CloudFront distributions had to disable before deleting.

The connector-owned log group `API-Gateway-Execution-Logs_7wz0kp5wyb/prod` is
**not** a stack resource and will survive the delete. Remove it by hand if you
care about the storage:

```bash
aws logs delete-log-group --log-group-name "API-Gateway-Execution-Logs_7wz0kp5wyb/prod" --region us-east-2
```

---

## Operations

```bash
# SSH
ssh -i ~/.ssh/mcropsey-lab-key.pem ec2-user@3.20.29.82

# Container status / logs
cd /opt/vampi && docker-compose ps
docker-compose logs -f
sudo tail -f /var/log/user-data.log   # UserData progress on fresh deploy

# Restart / re-seed
docker-compose restart
curl http://localhost:5000/createdb

# Flip vulnerable mode without a full redeploy
cd /opt/vampi
sed -i 's/vulnerable=1/vulnerable=0/' docker-compose.yml
docker-compose up -d --force-recreate
curl http://localhost:5000/createdb

# API GW errors — note this is the connector-owned execution log group, and the
# access-log lines in it are [NONAME]-delimited CSV, not JSON
aws logs filter-log-events --log-group-name "API-Gateway-Execution-Logs_7wz0kp5wyb/prod" \
  --region us-east-2 --filter-pattern '"[NONAME]"' \
  --query 'events[*].message' --output text | head -20

# Stack outputs (refresh live values after redeploy)
aws cloudformation describe-stacks --stack-name mcropsey-aws-gw-vampi --region us-east-2 \
  --query 'Stacks[0].Outputs[*].[OutputKey,OutputValue]' --output table

# Check for configuration drift (expect VampiStage MODIFIED — that's the connector)
aws cloudformation detect-stack-drift --stack-name mcropsey-aws-gw-vampi --region us-east-2
```

---

## Quick Test

```bash
BASE_URL=$(aws cloudformation describe-stacks --stack-name mcropsey-aws-gw-vampi \
  --region us-east-2 --query "Stacks[0].Outputs[?OutputKey=='ApiGatewayURL'].OutputValue" \
  --output text)
# currently: https://7wz0kp5wyb.execute-api.us-east-2.amazonaws.com/prod

# Home — confirms the gateway → EC2 path works
curl -s "$BASE_URL/" | jq .

# Seed / re-seed the database (idempotent)
curl -s "$BASE_URL/createdb" | jq .

# All users (basic info, no auth)
curl -s "$BASE_URL/users/v1" | jq .

# Login → token. Seeded users are name1/pass1, name2/pass2, admin/pass1 —
# confirm against /users/v1/_debug if the seed data ever changes upstream.
TOKEN=$(curl -s -X POST "$BASE_URL/users/v1/login" \
  -H "Content-Type: application/json" \
  -d '{"username":"name1","password":"pass1"}' | jq -r '.auth_token')

# Authenticated calls
curl -s "$BASE_URL/me" -H "Authorization: Bearer $TOKEN" | jq .
curl -s "$BASE_URL/books/v1" -H "Authorization: Bearer $TOKEN" | jq .
```

Or just run `./test-all-endpoints.sh`, which resolves the URL itself and walks
every endpoint. `./test-all-endpoints.sh --loop 5` repeats it to generate volume.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `{"message":"..."}` SQLAlchemy / no such table | DB never seeded | `curl "$BASE_URL/createdb"` |
| 502/503 from API GW | VAmPI still starting | Wait ~2 min; SSH → `docker-compose ps` + `sudo tail -f /var/log/user-data.log` |
| 504 Gateway Timeout | Container unhealthy | SSH → `cd /opt/vampi && docker-compose restart` |
| 403 on `/openapi.json` from Swagger UI | Connexion uses an absolute spec path; `/prod` prefix is missing | Use `http://3.20.29.82:5000/ui/`, or import the OpenAPI spec into Postman/Noname |
| 403 `Missing Authentication Token` from API GW | Hitting the API GW root without `/prod`, or a path with no matching method | Confirm the URL includes `/prod` |
| Token rejected immediately after login | `tokentimetolive` too short | Stack default is 3600s; check the `VampiTokenTTL` parameter |
| SSH permission denied | Wrong user or key perms | User is `ec2-user`; `chmod 400 ~/.ssh/mcropsey-lab-key.pem` |
| SSH times out | Your public IP changed | `AllowedSSHCIDR` is pinned to your `/32` at deploy time; re-run `./deploy-vampi.sh` |
| Noname not discovering API GW | Missing `inspected-by-noname-security` tag, or API GW is not REST v1 | See `noname-connector.md` gotchas 0 and 8 |
| Noname sees no traffic | Connection rule points at the old stack-id / old stack name | Rule value is now `mcropsey-aws-gw-vampi`, not `mcropsey-lab` |
| Noname resource stuck, Processor retrying every ~15 min | Empty-tag CreateLogGroup failure | See `noname-connector.md` gotcha 9 — the fix is `MethodSettings`, already in the template |
| Stack update fails on resource type change | In-place won't work | `./deploy-vampi.sh --fresh` |
| Scripts point at `ppcc9onu1h` / `3.135.133.6` | Pre-rename hardcoded values | Both are dead. Pull from stack outputs. |

---

## VAmPI Endpoints

BASE_URL: `https://7wz0kp5wyb.execute-api.us-east-2.amazonaws.com/prod`

### Setup / unauthenticated
| Method | Path | Notes |
|---|---|---|
| GET | `/` | Home — health check |
| GET | `/createdb` | Drops and repopulates the DB with dummy data |
| GET | `/users/v1` | All users, basic info |
| GET | `/users/v1/_debug` | **All users incl. passwords** — excessive data exposure |
| POST | `/users/v1/register` | Register — mass assignment target (`"admin": true`) |
| POST | `/users/v1/login` | Login → JWT — user/password enumeration, no rate limit |

### Users (Bearer)
| Method | Path | Notes |
|---|---|---|
| GET | `/me` | Current logged-in user |
| GET | `/users/v1/{username}` | SQLi target |
| DELETE | `/users/v1/{username}` | Admin only — BFLA target |
| PUT | `/users/v1/{username}/email` | RegexDOS target |
| PUT | `/users/v1/{username}/password` | Unauthorized password change (BOLA) |

### Books (Bearer)
| Method | Path | Notes |
|---|---|---|
| GET | `/books/v1` | All books |
| POST | `/books/v1` | Add book (title + secret) |
| GET | `/books/v1/{book}` | **BOLA target** — returns another user's secret |

### OWASP API Top 10 coverage

| Category | Where |
|---|---|
| API1 Broken Object Level Authorization | `GET /books/v1/{book}` |
| API2 Broken Authentication | Weak JWT signing key; enumeration on `/users/v1/login` |
| API3 Excessive Data Exposure | `GET /users/v1/_debug` |
| API4 Lack of Resources & Rate Limiting | No throttling on login; RegexDOS on email update |
| API5 Broken Function Level Authorization | `DELETE /users/v1/{username}` |
| API6 Mass Assignment | `POST /users/v1/register` |
| API7 Injection (SQLi) | `GET /users/v1/{username}` |
| API8 Unauthorized password change | `PUT /users/v1/{username}/password` |

All of the above are live when `vulnerable=1` (the default). Deploy with `--secure` to
get the same routes with the flaws patched.

---

## Optional: run both modes side by side

If you want a vulnerable and a patched instance simultaneously for A/B false-positive
testing, add a second service to `/opt/vampi/docker-compose.yml` on port 5001, open 5001
in the security group, and add a second `AWS::ApiGateway::RestApi` pointed at `:5001`.

Not included in the template by default — it doubles the gateway count and the whole
point of this conversion was to cut overhead. The second gateway would also need its
own `inspected-by-noname-security` tag and its own execution logging enabled, or Noname
will only ever see the first one.
