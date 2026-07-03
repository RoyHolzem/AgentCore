import { NextRequest } from 'next/server';
import { BedrockAgentCoreClient, InvokeHarnessCommand } from '@aws-sdk/client-bedrock-agentcore';

export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';
export const maxDuration = 60;

const REGION = process.env.HARNESS_REGION || 'eu-north-1';
const HARNESS_ARN = process.env.HARNESS_ARN || '';
const MODEL_ID = process.env.BEDROCK_MODEL_ID || 'eu.anthropic.claude-sonnet-4-5-20250929-v1:0';

function getClient() {
  return new BedrockAgentCoreClient({ region: REGION });
}

export async function POST(req: NextRequest) {
  const body = await req.json();
  const { messages, sessionId } = body;

  if (!messages || !Array.isArray(messages)) {
    return Response.json({ error: 'messages array required' }, { status: 400 });
  }

  // Debug: log env var state (redacted)
  console.log('HARNESS_ARN present:', !!HARNESS_ARN, 'length:', HARNESS_ARN.length);
  console.log('REGION:', REGION);
  console.log('MODEL_ID:', MODEL_ID);

  const harnessMessages = messages.map((m: { role: string; content: string }) => ({
    role: (m.role === 'assistant' ? 'assistant' : 'user') as 'user' | 'assistant',
    content: [{ text: m.content }],
  }));

  const sid = sessionId || crypto.randomUUID();

  const commandInput = {
    harnessArn: HARNESS_ARN,
    runtimeSessionId: sid,
    messages: harnessMessages,
    model: {
      bedrockModelConfig: {
        modelId: MODEL_ID,
      },
    },
  };

  console.log('Command input harnessArn:', commandInput.harnessArn);

  const encoder = new TextEncoder();

  const stream = new ReadableStream({
    async start(controller) {
      try {
        const client = getClient();
        const command = new InvokeHarnessCommand(commandInput);
        console.log('Command created, sending...');
        const response = await client.send(command);
        console.log('Response received');

        for await (const event of response.stream) {
          if (event.contentBlockDelta) {
            const delta = event.contentBlockDelta.delta;
            if (delta?.text) {
              controller.enqueue(
                encoder.encode(`data: ${JSON.stringify({ type: 'text', text: delta.text })}\n\n`)
              );
            }
          } else if (event.messageStop) {
            controller.enqueue(
              encoder.encode(`data: ${JSON.stringify({ type: 'stop', reason: event.messageStop.stopReason })}\n\n`)
            );
          } else if (event.metadata) {
            controller.enqueue(
              encoder.encode(`data: ${JSON.stringify({ type: 'metadata', usage: event.metadata.usage })}\n\n`)
            );
          }
        }
      } catch (err) {
        console.error('Harness invoke error:', err);
        const msg = err instanceof Error ? err.message : String(err);
        // Include more detail for debugging
        const detail = JSON.stringify({
          type: 'error',
          message: msg,
          harnessArnPresent: !!HARNESS_ARN,
          region: REGION,
        });
        controller.enqueue(encoder.encode(`data: ${detail}\n\n`));
      }

      controller.enqueue(encoder.encode('data: [DONE]\n\n'));
      controller.close();
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
