# mcropsey-lab — VAmPI + API Gateway
**Converted from crAPI:** 2026-08-25 | Region: us-east-2 | Stack: `mcropsey-lab`

> **After any redeploy**, refresh live values:
> ```bash
> aws cloudformation describe-stacks --stack-name mcropsey-lab --region us-east-2 \
>   --query 'Stacks[0].Outputs[*].[OutputKey,OutputValue]' --output table
> ```
> There are no CloudFront distributions in this stack. The API GW id changes on
> `--fresh` redeploy — update Live Values and the Noname connection rule.

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

---

## Live Values

Last deployed: 2026-08-25 | Stack: `mcropsey-lab` | Region: `us-east-2`

| | URL / Value |
|---|---|
| **VAmPI API** (BASE_URL) | `https://ppcc9onu1h.execute-api.us-east-2.amazonaws.com/prod` |
| **Swagger UI** (direct only — see note) | `http://3.135.133.6:5000/ui/` |
| **VAmPI direct** (bypasses GW) | `http://3.135.133.6:5000` |
| **Elastic IP** | `3.135.133.6` |
| **REST API GW id** | `ppcc9onu1h` |
| **SSH** | `ssh -i ~/.ssh/mcropsey-lab-key.pem ec2-user@3.135.133.6` |
| **Noname stack-id** | `arn:aws:cloudformation:us-east-2:491489166083:stack/mcropsey-lab/4a1d7240-a08e-11f1-8d50-0a6a3177c90f` |

---

## Architecture

```
                    ┌─────────────────────────────────────────────────────┐
                    │  mcropsey-lab CloudFormation Stack                  │
                    │                                                     │
You (HTTPS) ──────► │  REST API GW: mcropsey-lab-vampi-api                │
                    │    /prod stage → ANY / + ANY /{proxy+}              │
                    │    CloudWatch logs → Noname via Kinesis             │
                    │    └──► EC2 EIP:5000 → VAmPI container              │
                    │                                                     │
                    │  EC2 t3.small AL2023 @ 3.135.133.6                  │
                    │    Docker Compose /opt/vampi                        │
                    │    └─ erev0s/vampi:latest  → :5000  (SQLite, in-container)
                    │    └─ mcropsey-lab-vpc 10.2.0.0/16                  │
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
  from non-static AWS IPs.

### Swagger UI caveat

`/ui/` loads its own assets relatively and will render behind the gateway, but Connexion
points the UI at an **absolute** `/openapi.json`. The browser requests that at the domain
root, missing `/prod`, and gets a 403 — so "Try it out" won't work through the gateway.

This is cosmetic and has three workarounds, in order of preference:

1. Use the direct EIP URL: `http://3.135.133.6:5000/ui/`
2. Import `openapi_specs/openapi3.yml` from the VAmPI repo into Postman or Noname
   and set the server URL to your `/prod` base URL.
3. Ignore it — everything in Quick Test below works fine with curl.

---

## Deploy / Redeploy

```bash
cd ~/Downloads/aws-api-gw-crapi     # or wherever you keep the template

./deploy-vampi.sh            # deploy or update in place
./deploy-vampi.sh --fresh    # tear down completely and redeploy from scratch
./deploy-vampi.sh --secure   # deploy with vulnerable=0 (patched baseline)
```

**Migrating from the crAPI stack:** the resource set changed substantially, so an
in-place update won't work. Run `./deploy-vampi.sh --fresh` once. This deletes the
crAPI stack (including both CloudFront distributions) and builds the VAmPI stack under
the same `mcropsey-lab` name.

**Timing after `--fresh`:**
- CFN stack creates: ~3 min (no CloudFront — this is the big win)
- VAmPI image pulls + starts: ~1-2 min
- Total before fully usable: **~5-7 min** (was ~25-30 min)

The deploy script polls the API GW URL and runs a smoke test automatically, so you'll
know it's live before it exits.

**Prerequisites (one-time):** Key pair `mcropsey-lab-key` must exist in AWS us-east-2
with `~/.ssh/mcropsey-lab-key.pem` locally. AWS-generated keys break macOS OpenSSH 10+ —
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
  --filters "Name=tag:Name,Values=mcropsey-lab-instance" \
  --query "Reservations[0].Instances[0].InstanceId" --output text)

aws ec2 stop-instances --region us-east-2 --instance-ids "$INSTANCE_ID"
# or
aws ec2 start-instances --region us-east-2 --instance-ids "$INSTANCE_ID"
```

---

## Tear Down

```bash
aws cloudformation delete-stack --stack-name mcropsey-lab --region us-east-2
aws cloudformation wait stack-delete-complete --stack-name mcropsey-lab --region us-east-2
```

Faster than the crAPI teardown — CloudFront distributions had to disable before deleting.

---

## Operations

```bash
# SSH
ssh -i ~/.ssh/mcropsey-lab-key.pem ec2-user@3.135.133.6

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

# CloudWatch API GW errors
aws logs filter-log-events --log-group-name /aws/apigateway/mcropsey-lab-vampi \
  --region us-east-2 --filter-pattern '"status":"502"' \
  --query 'events[*].message' --output text

# Stack outputs (refresh live values after redeploy)
aws cloudformation describe-stacks --stack-name mcropsey-lab --region us-east-2 \
  --query 'Stacks[0].Outputs[*].[OutputKey,OutputValue]' --output table
```

---

## Quick Test

```bash
BASE_URL="https://ppcc9onu1h.execute-api.us-east-2.amazonaws.com/prod"

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

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `{"message":"..."}` SQLAlchemy / no such table | DB never seeded | `curl "$BASE_URL/createdb"` |
| 502/503 from API GW | VAmPI still starting | Wait ~2 min; SSH → `docker-compose ps` + `sudo tail -f /var/log/user-data.log` |
| 504 Gateway Timeout | Container unhealthy | SSH → `cd /opt/vampi && docker-compose restart` |
| 403 on `/openapi.json` from Swagger UI | Connexion uses an absolute spec path; `/prod` prefix is missing | Use `http://3.135.133.6:5000/ui/`, or import the OpenAPI spec into Postman/Noname |
| 403 `Missing Authentication Token` from API GW | Hitting the API GW root without `/prod`, or a path with no matching method | Confirm the URL includes `/prod` |
| Token rejected immediately after login | `tokentimetolive` too short | Stack default is 3600s; check the `VampiTokenTTL` parameter |
| SSH permission denied | Wrong user or key perms | User is `ec2-user`; `chmod 400 ~/.ssh/mcropsey-lab-key.pem` |
| Noname not discovering API GW | API GW must be REST v1 type | Confirm stack uses `AWS::ApiGateway::RestApi`, not `AWS::ApiGatewayV2::Api` |
| Noname sees no traffic after conversion | Connection rule still points at the old stack-id, or the old crAPI log group | Update the rule (see noname-connector.md) |
| Stack update fails on resource type change | In-place won't work | `./deploy-vampi.sh --fresh` |

---

## VAmPI Endpoints — BASE_URL: `https://ppcc9onu1h.execute-api.us-east-2.amazonaws.com/prod`

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
point of this conversion was to cut overhead.
