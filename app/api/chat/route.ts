import { NextRequest } from 'next/server';

export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

const REGION = process.env.HARNESS_REGION || 'eu-north-1';
const HARNESS_ARN = process.env.HARNESS_ARN!;
const MODEL_ID = process.env.BEDROCK_MODEL_ID || 'eu.anthropic.claude-sonnet-4-5-20250929-v1:0';

// Lazy-init AWS SDK (avoid loading on cold start until needed)
let _client: any = null;
async function getClient() {
  if (_client) return _client;
  const { default: boto3 } = await import('child_process');
  // We use the Python boto3 via a helper script for InvokeHarness
  // since @aws-sdk/client-bedrock-agentcore doesn't exist yet.
  // Instead, we'll shell out to a Python script that does the streaming.
  return null;
}

export async function POST(req: NextRequest) {
  const body = await req.json();
  const { messages, sessionId } = body;

  if (!messages || !Array.isArray(messages)) {
    return new Response(JSON.stringify({ error: 'messages array required' }), {
      status: 400,
      headers: { 'Content-Type': 'application/json' },
    });
  }

  const { spawn } = await import('child_process');

  const payload = JSON.stringify({
    messages,
    sessionId: sessionId || crypto.randomUUID(),
    harnessArn: HARNESS_ARN,
    modelId: MODEL_ID,
    region: REGION,
  });

  const encoder = new TextEncoder();

  const stream = new ReadableStream({
    start(controller) {
      const py = spawn('python', ['-c', PYTHON_SCRIPT], {
        env: { ...process.env },
      });

      py.stdin.write(payload);
      py.stdin.end();

      let buffer = '';

      py.stdout.on('data', (data: Buffer) => {
        buffer += data.toString();
        const lines = buffer.split('\n');
        buffer = lines.pop() || '';

        for (const line of lines) {
          if (!line.trim()) continue;
          try {
            const evt = JSON.parse(line);
            if (evt.type === 'text') {
              controller.enqueue(encoder.encode(`data: ${JSON.stringify({ type: 'text', text: evt.text })}\n\n`));
            } else if (evt.type === 'stop') {
              controller.enqueue(encoder.encode(`data: ${JSON.stringify({ type: 'stop', reason: evt.reason })}\n\n`));
            } else if (evt.type === 'metadata') {
              controller.enqueue(encoder.encode(`data: ${JSON.stringify({ type: 'metadata', ...evt.data })}\n\n`));
            } else if (evt.type === 'error') {
              controller.enqueue(encoder.encode(`data: ${JSON.stringify({ type: 'error', message: evt.message })}\n\n`));
            }
          } catch {
            // skip non-JSON lines
          }
        }
      });

      py.stderr.on('data', (data: Buffer) => {
        const msg = data.toString().trim();
        if (msg) {
          controller.enqueue(encoder.encode(`data: ${JSON.stringify({ type: 'error', message: msg })}\n\n`));
        }
      });

      py.on('close', () => {
        // flush remaining buffer
        if (buffer.trim()) {
          try {
            const evt = JSON.parse(buffer);
            if (evt.type === 'text') {
              controller.enqueue(encoder.encode(`data: ${JSON.stringify({ type: 'text', text: evt.text })}\n\n`));
            }
          } catch { /* ignore */ }
        }
        controller.enqueue(encoder.encode('data: [DONE]\n\n'));
        controller.close();
      });
    },
  });

  return new Response(stream, {
    headers: {
      'Content-Type': 'text/event-stream',
      'Cache-Control': 'no-cache',
      'Connection': 'keep-alive',
    },
  });
}

const PYTHON_SCRIPT = `
import sys, json, uuid, boto3

payload = json.loads(sys.stdin.buffer.read().decode())
region = payload['region']
harness_arn = payload['harnessArn']
model_id = payload['modelId']
session_id = payload['sessionId']
messages = payload['messages']

# Map role/content to HarnessMessage format
harness_messages = []
for m in messages:
    role = m.get('role', 'user')
    content = m.get('content', '')
    if isinstance(content, str):
        content = [{'text': content}]
    elif isinstance(content, list) and content and isinstance(content[0], str):
        content = [{'text': c} for c in content]
    harness_messages.append({'role': role, 'content': content})

session = boto3.Session(region_name=region)
client = session.client('bedrock-agentcore', region_name=region)

try:
    response = client.invoke_harness(
        harnessArn=harness_arn,
        runtimeSessionId=session_id,
        messages=harness_messages,
        model={'bedrockModelConfig': {'modelId': model_id}}
    )

    for event in response.get('stream', []):
        if 'contentBlockDelta' in event:
            delta = event['contentBlockDelta'].get('delta', {})
            if 'text' in delta:
                print(json.dumps({'type': 'text', 'text': delta['text']}), flush=True)
        elif 'messageStop' in event:
            reason = event['messageStop'].get('stopReason', 'unknown')
            print(json.dumps({'type': 'stop', 'reason': reason}), flush=True)
        elif 'metadata' in event:
            print(json.dumps({'type': 'metadata', 'data': event['metadata']}), flush=True)
except Exception as e:
    print(json.dumps({'type': 'error', 'message': str(e)}), flush=True)
`;
