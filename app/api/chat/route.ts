import { NextRequest } from 'next/server';
import { BedrockAgentCoreClient, InvokeHarnessCommand } from '@aws-sdk/client-bedrock-agentcore';

export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';
export const maxDuration = 60;

const REGION = process.env.HARNESS_REGION || 'eu-north-1';
const HARNESS_ARN = process.env.HARNESS_ARN || '';
const MODEL_ID = process.env.BEDROCK_MODEL_ID || 'eu.amazon.nova-pro-v1:0';

function getClient() {
  return new BedrockAgentCoreClient({ region: REGION });
}

export async function POST(req: NextRequest) {
  const body = await req.json();
  const { messages, sessionId } = body;

  if (!messages || !Array.isArray(messages)) {
    return Response.json({ error: 'messages array required' }, { status: 400 });
  }

  const harnessMessages = messages.map((m: { role: string; content: string }) => ({
    role: (m.role === 'assistant' ? 'assistant' : 'user') as 'user' | 'assistant',
    content: [{ text: m.content }],
  }));

  const sid = sessionId || crypto.randomUUID();

  const command = new InvokeHarnessCommand({
    harnessArn: HARNESS_ARN,
    runtimeSessionId: sid,
    messages: harnessMessages,
    model: {
      bedrockModelConfig: {
        modelId: MODEL_ID,
      },
    },
    systemPrompt: [
      { text: 'You are a helpful, concise AI assistant. Answer questions directly and honestly. Never mention AWS, DynamoDB, telecom, or tables unless the user specifically asks about them. Do not invent context about the user\'s projects or intentions.' },
    ],
  });

  const encoder = new TextEncoder();

  const stream = new ReadableStream({
    async start(controller) {
      try {
        const client = getClient();
        const response = await client.send(command);

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
        const msg = err instanceof Error ? err.message : String(err);
        controller.enqueue(
          encoder.encode(`data: ${JSON.stringify({ type: 'error', message: msg })}\n\n`)
        );
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
