/**
 * Minimal fetch mock for adapter tests.
 *
 * Records every call (url, method, parsed JSON body) and returns whatever the
 * supplied responder produces. Restores the real fetch on stop().
 */

export interface RecordedCall {
  url: string;
  method: string;
  body: unknown;
}

/** A Response-like object exposing only what the adapters actually use. */
export interface FakeResponse {
  ok: boolean;
  status: number;
  statusText: string;
  json: () => Promise<unknown>;
  text: () => Promise<string>;
}

export function jsonResponse(data: unknown, ok = true, status = 200): FakeResponse {
  return {
    ok,
    status,
    statusText: ok ? 'OK' : 'Error',
    json: async () => data,
    text: async () => JSON.stringify(data),
  };
}

export type Responder = (call: RecordedCall) => FakeResponse;

export interface FetchMock {
  calls: RecordedCall[];
  /** Calls filtered by HTTP method (case-insensitive). */
  callsOfMethod: (method: string) => RecordedCall[];
  stop: () => void;
}

/**
 * Install a fake global fetch. Default responder returns an empty 200 JSON body.
 */
export function installFetchMock(responder: Responder = () => jsonResponse({})): FetchMock {
  const calls: RecordedCall[] = [];
  const realFetch = globalThis.fetch;

  globalThis.fetch = ((input: unknown, init?: { method?: string; body?: unknown }) => {
    const bodyRaw = init?.body;
    let body: unknown;
    if (typeof bodyRaw === 'string') {
      try {
        body = JSON.parse(bodyRaw);
      } catch {
        body = bodyRaw;
      }
    }
    const call: RecordedCall = {
      url: String(input),
      method: (init?.method ?? 'GET').toUpperCase(),
      body,
    };
    calls.push(call);
    return Promise.resolve(responder(call) as unknown as Response);
  }) as typeof fetch;

  return {
    calls,
    callsOfMethod: (method: string) =>
      calls.filter(c => c.method === method.toUpperCase()),
    stop: () => {
      globalThis.fetch = realFetch;
    },
  };
}
