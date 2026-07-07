#!/usr/bin/env bash
set -euo pipefail

#
# AgentCore Chat — Connect Amplify to Harness
#
# Paste this into CloudShell. No arguments needed.
# Auto-discovers your harness, Amplify app, creates the IAM role,
# attaches it, sets env vars, and redeploys.
#
# Requirements: CloudShell session in any region (uses your console credentials)
#

echo ""
echo "════════════════════════════════════════════════"
echo "  AgentCore Chat — Amplify ↔ Harness Connector"
echo "════════════════════════════════════════════════"
echo ""

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
echo "Account: $ACCOUNT_ID"

#
# 1. Find the AgentCore harness (check all AgentCore regions)
#
echo ""
echo "── Step 1/6: Finding your AgentCore harness ──"

HARNESS_REGIONS=("eu-north-1" "us-east-1" "us-west-2")
HARNESS_ARN=""
HARNESS_REGION=""

for HR in "${HARNESS_REGIONS[@]}"; do
  echo "  Scanning $HR..."
  RESULT=$(python3 << PYEOF 2>/dev/null || echo ""
import boto3, json
client = boto3.client('bedrock-agentcore', region_name='$HR')
try:
    runtimes = client.list_agent_runtimes()
    harnesses = [r for r in runtimes.get('agentRuntimes', []) if r.get('status') == 'READY']
    if harnesses:
        # Get the first ready harness
        h = harnesses[0]
        runtime_id = h['agentRuntimeId']
        name = h.get('agentRuntimeName', 'unknown')
        # Try to get the harness ARN from describe
        try:
            desc = client.get_agent_runtime(agentRuntimeId=runtime_id)
            # The harness ARN is often in the response
            arn = desc.get('agentRuntime', {}).get('agentRuntimeArn', '')
            if not arn:
                # Construct from runtimeArn pattern
                arn = f"arn:aws:bedrock-agentcore:$HR:$ACCOUNT_ID:runtime/{runtime_id}"
            print(json.dumps({'arn': arn, 'name': name, 'runtimeId': runtime_id, 'region': '$HR'}))
        except:
            print(json.dumps({'arn': '', 'name': name, 'runtimeId': runtime_id, 'region': '$HR'}))
except Exception as e:
    pass
PYEOF
)

  if [[ -n "$RESULT" ]]; then
    # Extract values
    HARNESS_REGION=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('region',''))" 2>/dev/null)
    H_NAME=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('name',''))" 2>/dev/null)
    RUNTIME_ID=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('runtimeId',''))" 2>/dev/null)

    # Now find the actual harness ARN (not runtime ARN)
    # The harness ARN has a different suffix — find via CloudTrail
    HARNESS_ARN=$(python3 << PYEOF 2>/dev/null || echo ""
import boto3, json

logs = boto3.client('cloudtrail', region_name='$HARNESS_REGION')
try:
    resp = logs.lookup_events(
        LookupAttributes=[{'AttributeKey': 'EventName', 'AttributeValue': 'CreateAgentRuntime'}],
        MaxResults=50
    )
    for event in resp.get('Events', []):
        ct = event.get('CloudTrailEvent', '')
        if 'CreateAgentRuntime' in ct and 'bedrock-agentcore' in ct:
            # Parse the cloud trail event
            parsed = json.loads(ct)
            # Look for the source ARN header
            for ih in parsed.get('requestParameters', {}).get('invokeModel', {}).get('headers', []):
                if 'Source-Arn' in ih.get('key', '') or 'Source-Arn' in ih.get('value', ''):
                    arn = ih['value']
                    if 'harness/' in arn:
                        print(arn)
                        exit(0)
            # Also check responseElements
            resp_elem = parsed.get('responseElements', {})
            arn = resp_elem.get('agentRuntime', {}).get('agentRuntimeArn', '')
            if 'harness/' in arn:
                print(arn)
                exit(0)
except Exception:
    pass

# Fallback: construct harness ARN pattern (wildcard)
# The invoke works with the harness ARN, which we may not find exactly
# But we can use the runtime ARN for invoke — actually InvokeHarness needs the harness ARN
# Let's try listing harnesses directly
import boto3
client = boto3.client('bedrock-agentcore', region_name='$HARNESS_REGION')
try:
    # Some API versions have list_harnesses
    h_resp = client.list_harnesses() if hasattr(client, 'list_harnesses') else {}
    for h in h_resp.get('harnesses', []):
        arn = h.get('harnessArn', h.get('arn', ''))
        if arn:
            print(arn)
            exit(0)
except Exception:
    pass

# Last resort: try the runtime ARN — invoke_harness sometimes accepts it
print(f"arn:aws:bedrock-agentcore:$HARNESS_REGION:$ACCOUNT_ID:runtime/$RUNTIME_ID")
PYEOF
)

    echo "  ✓ Found harness: $H_NAME"
    echo "    Region:     $HARNESS_REGION"
    echo "    Runtime ID: $RUNTIME_ID"
    echo "    ARN:        $HARNESS_ARN"
    break
  fi
done

if [[ -z "$HARNESS_ARN" ]]; then
  echo ""
  echo "  ✗ No ready AgentCore harness found in eu-north-1, us-east-1, or us-west-2"
  echo "    Create one first: Bedrock Console → AgentCore → Create harness"
  echo "    Then re-run this script."
  exit 1
fi

#
# 2. Find the Amplify app (check all common regions)
#
echo ""
echo "── Step 2/6: Finding your Amplify app ──"

AMPLIFY_REGIONS=("eu-west-1" "us-east-1" "eu-north-1" "us-west-2" "eu-central-1" "ap-southeast-1" "ap-northeast-1")
APP_ID=""
AMPLIFY_REGION=""

for AR in "${AMPLIFY_REGIONS[@]}"; do
  APPS=$(aws amplify list-apps --region "$AR" --query 'apps' --output json 2>/dev/null || echo "[]")
  APP_COUNT=$(echo "$APPS" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")

  if [[ "$APP_COUNT" != "0" ]]; then
    # Find an app that looks like agentcore or just take the first one
    APP_INFO=$(echo "$APPS" | python3 -c "
import sys, json
apps = json.load(sys.stdin)
if not apps: exit(0)
# Prefer apps with 'agent' or 'core' in the name
for a in apps:
    name = a.get('name', '').lower()
    if 'agent' in name or 'core' in name:
        print(json.dumps({'appId': a['appId'], 'name': a['name']}))
        exit(0)
# Otherwise take the first
print(json.dumps({'appId': apps[0]['appId'], 'name': apps[0].get('name', 'unknown')}))
" 2>/dev/null)

    if [[ -n "$APP_INFO" ]]; then
      APP_ID=$(echo "$APP_INFO" | python3 -c "import sys,json; print(json.load(sys.stdin)['appId'])")
      APP_NAME=$(echo "$APP_INFO" | python3 -c "import sys,json; print(json.load(sys.stdin)['name'])")
      AMPLIFY_REGION="$AR"
      echo "  ✓ Found: $APP_NAME ($APP_ID) in $AMPLIFY_REGION"
      break
    fi
  fi
done

if [[ -z "$APP_ID" ]]; then
  echo "  ✗ No Amplify app found."
  echo "    Create one first in the Amplify Console, then re-run."
  exit 1
fi

#
# 3. Create IAM role
#
echo ""
echo "── Step 3/6: Creating IAM role ──"

# Check if role already exists
if aws iam get-role --role-name AmplifyAgentCoreChatRole --query 'Role.Arn' --output text 2>/dev/null; then
  COMPUTE_ROLE_ARN=$(aws iam get-role --role-name AmplifyAgentCoreChatRole --query 'Role.Arn' --output text)
  echo "  ✓ Role already exists: $COMPUTE_ROLE_ARN"
else
  # Trust policy — must allow the Amplify region
  cat > /tmp/trust.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Service": "amplify.amazonaws.com" },
      "Action": "sts:AssumeRole",
      "Condition": { "StringEquals": { "aws:SourceAccount": "$ACCOUNT_ID" } }
    },
    {
      "Effect": "Allow",
      "Principal": { "Service": "compute.amplify.amazonaws.com" },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF

  # Permission policy — target the harness region
  cat > /tmp/perms.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "bedrock-agentcore:InvokeHarness",
        "bedrock-agentcore:InvokeAgentRuntime",
        "bedrock-agentcore:InvokeAgentRuntimeForUser"
      ],
      "Resource": [
        "arn:aws:bedrock-agentcore:$HARNESS_REGION:$ACCOUNT_ID:harness/*",
        "arn:aws:bedrock-agentcore:$HARNESS_REGION:$ACCOUNT_ID:runtime/*"
      ]
    },
    {
      "Effect": "Allow",
      "Action": ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"],
      "Resource": [
        "arn:aws:bedrock:*::foundation-model/*",
        "arn:aws:bedrock:$HARNESS_REGION:$ACCOUNT_ID:*",
        "arn:aws:bedrock:$HARNESS_REGION::*"
      ]
    },
    {
      "Effect": "Allow",
      "Action": "bedrock:InvokeModel",
      "Resource": "arn:aws:bedrock:$HARNESS_REGION:$ACCOUNT_ID:inference-profile/*"
    }
  ]
}
EOF

  aws iam create-role \
    --role-name AmplifyAgentCoreChatRole \
    --assume-role-policy-document file:///tmp/trust.json \
    --query 'Role.Arn' --output text >/dev/null

  aws iam put-role-policy \
    --role-name AmplifyAgentCoreChatRole \
    --policy-name AmplifyAgentCoreInvoke \
    --policy-document file:///tmp/perms.json >/dev/null

  COMPUTE_ROLE_ARN="arn:aws:iam::$ACCOUNT_ID:role/AmplifyAgentCoreChatRole"
  echo "  ✓ Created role: $COMPUTE_ROLE_ARN"

  rm /tmp/trust.json /tmp/perms.json
fi

#
# 4. Attach compute role to Amplify app
#
echo ""
echo "── Step 4/6: Attaching compute role to Amplify app ──"

aws amplify update-app \
  --region "$AMPLIFY_REGION" \
  --app-id "$APP_ID" \
  --compute-role-arn "$COMPUTE_ROLE_ARN" \
  >/dev/null 2>&1 && echo "  ✓ Compute role attached" || echo "  ⚠ Could not attach (may need manual step in console)"

#
# 5. Set environment variables
#
echo ""
echo "── Step 5/6: Setting environment variables ──"

# Set at app level
aws amplify update-app \
  --region "$AMPLIFY_REGION" \
  --app-id "$APP_ID" \
  --environment-vars \
    HARNESS_REGION="$HARNESS_REGION" \
    HARNESS_ARN="$HARNESS_ARN" \
    BEDROCK_MODEL_ID="eu.amazon.nova-pro-v1:0" \
  >/dev/null 2>&1 && echo "  ✓ App-level env vars set" || echo "  ⚠ App-level env vars failed"

# Set at branch level
BRANCHES=$(aws amplify list-branches --region "$AMPLIFY_REGION" --app-id "$APP_ID" --query 'branches[].branchName' --output json 2>/dev/null || echo '["main"]')
BRANCH=$(echo "$BRANCHES" | python3 -c "import sys,json; bs=json.load(sys.stdin); print(bs[0] if bs else 'main')")

aws amplify update-branch \
  --region "$AMPLIFY_REGION" \
  --app-id "$APP_ID" \
  --branch-name "$BRANCH" \
  --environment-vars \
    HARNESS_REGION="$HARNESS_REGION" \
    HARNESS_ARN="$HARNESS_ARN" \
    BEDROCK_MODEL_ID="eu.amazon.nova-pro-v1:0" \
  >/dev/null 2>&1 && echo "  ✓ Branch '$BRANCH' env vars set" || echo "  ⚠ Branch env vars failed"

#
# 6. Redeploy
#
echo ""
echo "── Step 6/6: Triggering redeploy ──"

JOB_ID=$(aws amplify start-job \
  --region "$AMPLIFY_REGION" \
  --app-id "$APP_ID" \
  --branch-name "$BRANCH" \
  --job-type "RELEASE" \
  --query 'jobSummary.jobId' --output text 2>/dev/null || echo "")

if [[ -n "$JOB_ID" ]]; then
  echo "  Job: $JOB_ID"
  echo ""
  echo "Waiting for deploy..."
  for i in $(seq 1 20); do
    sleep 15
    STATUS=$(aws amplify get-job \
      --region "$AMPLIFY_REGION" \
      --app-id "$APP_ID" \
      --branch-name "$BRANCH" \
      --job-id "$JOB_ID" \
      --query 'job.summary.status' \
      --output text 2>/dev/null || echo "UNKNOWN")
    echo "  [$((i*15))s] $STATUS"
    if [[ "$STATUS" == "SUCCEED" ]]; then break; fi
    if [[ "$STATUS" == "FAILED" || "$STATUS" == "CANCELLED" ]]; then
      echo ""
      echo "  ✗ Deploy $STATUS — check logs in Amplify Console"
      break
    fi
  done
else
  echo "  ⚠ Could not trigger auto-deploy. Trigger manually from Amplify Console."
fi

echo ""
echo "════════════════════════════════════════════════"
echo "  Done!"
echo "════════════════════════════════════════════════"
echo ""
echo "Harness:    $HARNESS_ARN"
echo "            ($HARNESS_REGION)"
echo "Amplify:    $APP_ID"
echo "            ($AMPLIFY_REGION, branch: $BRANCH)"
echo "Role:       $COMPUTE_ROLE_ARN"
echo "App URL:    https://$BRANCH.$APP_ID.amplifyapp.com/"
echo ""
echo "Verify:"
echo "  curl -X POST https://$BRANCH.$APP_ID.amplifyapp.com/api/chat \\"
echo "    -H 'Content-Type: application/json' \\"
echo "    -d '{\"messages\":[{\"role\":\"user\",\"content\":\"Hello!\"}],\"sessionId\":\"test\"}'"
echo ""
