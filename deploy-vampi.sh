#!/bin/bash
# usage:
#   ./deploy-vampi.sh           # deploy or update the stack in place
#   ./deploy-vampi.sh --fresh   # tear down completely and redeploy from scratch
#   ./deploy-vampi.sh --secure  # deploy with vulnerabilities patched (vulnerable=0)
#
# Prerequisites:
#   - AWS CLI configured (aws sts get-caller-identity works)
#   - Key pair 'mcropsey-lab-key' imported into AWS us-east-2
#   - Private key at ~/.ssh/mcropsey-lab-key.pem (chmod 400)
#
# Timing (--fresh):  ~5-7 min total, no CloudFront propagation wait.
#   ~3 min  — CloudFormation stack creates
#   ~2 min  — VAmPI image pulls (41 MB) and Flask starts
#   ~0 min  — API GW URL is live immediately; no global propagation delay

set -euo pipefail

# Every resource name and tag in the stack derives from PREFIX. Its twin
# environment lives in ../aws-f5-vampi (prefix mcropsey-f5) and shares nothing
# with this one: separate VPC, separate stack, separate API surface.
PREFIX="mcropsey-aws-gw"
STACK="mcropsey-aws-gw-vampi"
REGION="us-east-2"
KEY_PAIR="mcropsey-lab-key"
TEMPLATE="$(dirname "$0")/mcropsey-lab-vampi-apigw.yaml"
MY_IP="$(curl -s https://checkip.amazonaws.com)/32"

FRESH=0
VULN=1
if [[ $# -gt 0 ]]; then
  for arg in "$@"; do
    case "$arg" in
      --fresh)  FRESH=1 ;;
      --secure) VULN=0 ;;
      *) echo "ERROR: unknown flag '$arg' (expected --fresh and/or --secure)"; exit 1 ;;
    esac
  done
fi

# ── Pre-flight checks ──────────────────────────────────────────────────────

if ! aws sts get-caller-identity --query Account --output text >/dev/null 2>&1; then
  echo "ERROR: AWS CLI not configured or no valid credentials. Run 'aws configure'."
  exit 1
fi

if [[ ! -f "$TEMPLATE" ]]; then
  echo "ERROR: Template not found: $TEMPLATE"
  exit 1
fi

PEM_FILE="$HOME/.ssh/${KEY_PAIR}.pem"
if [[ ! -f "$PEM_FILE" ]]; then
  echo "WARNING: PEM file not found at $PEM_FILE"
  echo "         Continuing — key pair must exist in AWS as: $KEY_PAIR"
else
  chmod 400 "$PEM_FILE"
fi

echo "==> AWS account: $(aws sts get-caller-identity --query Account --output text)"
echo "==> Prefix:      $PREFIX"
echo "==> Region:      $REGION"
echo "==> Stack:       $STACK"
echo "==> Key pair:    $KEY_PAIR"
echo "==> SSH CIDR:    $MY_IP"
echo "==> VAmPI mode:  $([[ "$VULN" == "1" ]] && echo 'VULNERABLE' || echo 'secure (patched)')"

# ── Optional teardown ──────────────────────────────────────────────────────

if [[ "$FRESH" == "1" ]]; then
  echo ""
  echo "==> --fresh: deleting existing stack '$STACK' ..."
  aws cloudformation delete-stack --stack-name "$STACK" --region "$REGION" 2>/dev/null || true
  echo "==> Waiting for deletion to complete (this can take a few minutes)..."
  aws cloudformation wait stack-delete-complete --stack-name "$STACK" --region "$REGION" 2>/dev/null || true
  echo "==> Stack deleted."
  echo ""
  echo "    REMINDER: a fresh stack gets a NEW stack-id and a NEW API GW id."
  echo "    If your Noname connection rule matches on 'aws:cloudformation:stack-id',"
  echo "    update it with the new ARN printed below."
fi

# ── Deploy ─────────────────────────────────────────────────────────────────

echo ""
echo "==> Deploying CloudFormation stack..."
aws cloudformation deploy \
  --template-file "$TEMPLATE" \
  --stack-name "$STACK" \
  --region "$REGION" \
  --parameter-overrides \
    Prefix="$PREFIX" \
    KeyPairName="$KEY_PAIR" \
    AllowedSSHCIDR="$MY_IP" \
    VampiVulnerable="$VULN"

# ── Show outputs ───────────────────────────────────────────────────────────

echo ""
echo "==> Stack deployed. Outputs:"
aws cloudformation describe-stacks \
  --stack-name "$STACK" \
  --region "$REGION" \
  --query 'Stacks[0].Outputs[*].[OutputKey,OutputValue]' \
  --output table

# ── Extract key values ─────────────────────────────────────────────────────

get_output() {
  aws cloudformation describe-stacks \
    --stack-name "$STACK" --region "$REGION" \
    --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" \
    --output text
}

BASE_URL=$(get_output ApiGatewayURL)
SWAGGER=$(get_output SwaggerUIDirect)
DIRECT=$(get_output VampiDirect)
API_ID=$(get_output RestApiId)
EIP=$(get_output ElasticIP)

STACK_ID=$(aws cloudformation describe-stacks \
  --stack-name "$STACK" --region "$REGION" \
  --query 'Stacks[0].StackId' --output text)

echo ""
echo "╔══════════════════════════════════════════════════════════════════════╗"
echo "║  KEY URLS — update mcropsey-lab-vampi-apigw.md with these values     ║"
echo "╠══════════════════════════════════════════════════════════════════════╣"
echo "║  VAmPI (BASE_URL):     $BASE_URL"
echo "║  Swagger UI (direct):  $SWAGGER"
echo "║  VAmPI direct:         $DIRECT"
echo "║  REST API GW id:       $API_ID"
echo "║  Elastic IP:           $EIP"
echo "║  SSH:                  ssh -i ~/.ssh/mcropsey-lab-key.pem ec2-user@$EIP"
echo "╚══════════════════════════════════════════════════════════════════════╝"
echo ""
echo "Noname connection rule (tag key: aws:cloudformation:stack-id):"
echo "  $STACK_ID"

# ── Wait for VAmPI, then smoke test ────────────────────────────────────────

echo ""
echo "==> Waiting for VAmPI to come up (image pull + Flask start, ~2 min)..."
READY=0
for i in $(seq 1 40); do
  if curl -fsS --max-time 5 "$BASE_URL/" >/dev/null 2>&1; then
    READY=1
    echo "==> VAmPI responding after $((i * 10))s"
    break
  fi
  sleep 10
done

if [[ "$READY" != "1" ]]; then
  echo "!!! VAmPI did not respond within ~7 min."
  echo "!!! Check startup: ssh -i ~/.ssh/${KEY_PAIR}.pem ec2-user@$EIP"
  echo "!!!                sudo tail -f /var/log/user-data.log"
  exit 1
fi

echo ""
echo "==> Smoke test through the API Gateway"

echo "--- GET / ---"
curl -fsS "$BASE_URL/" || true; echo ""

echo "--- GET /createdb (idempotent re-seed) ---"
curl -fsS "$BASE_URL/createdb" || true; echo ""

echo "--- GET /users/v1 ---"
curl -fsS "$BASE_URL/users/v1" || true; echo ""

echo "--- POST /users/v1/login (name1/pass1) ---"
curl -fsS -X POST "$BASE_URL/users/v1/login" \
  -H "Content-Type: application/json" \
  -d '{"username":"name1","password":"pass1"}' || true; echo ""

echo ""
echo "NOTES:"
echo "  - No CloudFront in this stack: the /prod URL above IS the base URL."
echo "  - 100% of traffic to BASE_URL flows through the REST API GW → Noname."
echo "  - Swagger UI must be reached on the DIRECT EIP URL. Connexion points the"
echo "    UI at an absolute /openapi.json, which 403s behind the /prod prefix."
echo "  - Re-seed the DB any time with: curl $BASE_URL/createdb"
echo "  - Flip to patched mode for false-positive testing: ./deploy-vampi.sh --secure"
echo "  - The F5-fronted twin of this lab: ../aws-f5-vampi (prefix mcropsey-f5)"
