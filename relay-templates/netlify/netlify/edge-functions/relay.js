export const config = { path: "/*" };

const TARGET_BASE = __TARGET_BASE_JSON__;
const PUBLIC_PATH = __PUBLIC_PATH_JSON__;
const RELAY_PATH = __RELAY_PATH_JSON__;
const RELAY_TOKEN = __RELAY_TOKEN_JSON__;
const ALLOWED_CLIENT_IPS = __CLIENT_IPS_JSON__;

function mapPath(pathname) {
  if (pathname === PUBLIC_PATH) return RELAY_PATH;
  if (pathname.startsWith(PUBLIC_PATH + "/")) {
    return RELAY_PATH + pathname.slice(PUBLIC_PATH.length);
  }
  return null;
}

function clientIp(request) {
  const forwarded = request.headers.get("x-forwarded-for") || "";
  const first = forwarded.split(",")[0].trim();
  return first || request.headers.get("x-real-ip") || "";
}

function isAllowedClient(request) {
  if (!ALLOWED_CLIENT_IPS.length) return true;
  return ALLOWED_CLIENT_IPS.includes(clientIp(request));
}

export default async function handler(request) {
  try {
    const url = new URL(request.url);
    if (url.pathname === "/") return new Response("OK", { status: 200 });

    const upstreamPath = mapPath(url.pathname);
    if (!upstreamPath) return new Response("Not Found", { status: 404 });
    if (!isAllowedClient(request)) return new Response("Forbidden", { status: 403 });
    if (RELAY_TOKEN && url.searchParams.get("k") !== RELAY_TOKEN) {
      return new Response("Forbidden", { status: 403 });
    }
    url.searchParams.delete("k");

    const headers = new Headers();
    for (const [key, value] of request.headers) {
      const k = key.toLowerCase();
      if ([
        "host",
        "connection",
        "transfer-encoding",
        "upgrade",
        "forwarded",
        "x-forwarded-for",
        "x-forwarded-host",
        "x-forwarded-proto",
        "x-forwarded-port",
        "x-real-ip",
        "client-ip",
        "true-client-ip",
        "cf-connecting-ip"
      ].includes(k)) continue;
      if (k.startsWith("x-nf-") || k.startsWith("x-netlify-")) continue;
      headers.set(k, value);
    }

    const opts = { method: request.method, headers, redirect: "manual" };
    if (request.method !== "GET" && request.method !== "HEAD") {
      opts.body = request.body;
    }

    const search = url.searchParams.toString();
    const upstream = await fetch(TARGET_BASE + upstreamPath + (search ? "?" + search : ""), opts);
    const responseHeaders = new Headers();
    for (const [key, value] of upstream.headers) {
      if (key.toLowerCase() !== "transfer-encoding") {
        responseHeaders.set(key, value);
      }
    }
    return new Response(upstream.body, {
      status: upstream.status,
      headers: responseHeaders
    });
  } catch {
    return new Response("Bad Gateway", { status: 502 });
  }
}
