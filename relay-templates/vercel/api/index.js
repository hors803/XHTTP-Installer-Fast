import { Readable } from "node:stream";

export const config = {
  api: { bodyParser: false },
  supportsResponseStreaming: true,
  maxDuration: 60
};

const TARGET_BASE = __TARGET_BASE_JSON__;
const PUBLIC_PATH = __PUBLIC_PATH_JSON__;
const RELAY_PATH = __RELAY_PATH_JSON__;

function mapPath(pathname) {
  if (pathname === PUBLIC_PATH) return RELAY_PATH;
  if (pathname.startsWith(PUBLIC_PATH + "/")) {
    return RELAY_PATH + pathname.slice(PUBLIC_PATH.length);
  }
  return null;
}

export default async function handler(req, res) {
  try {
    const host = req.headers.host || "localhost";
    const url = new URL(req.url || "/", "https://" + host);
    if (url.pathname === "/") {
      res.statusCode = 200;
      return res.end("OK");
    }

    const upstreamPath = mapPath(url.pathname);
    if (!upstreamPath) {
      res.statusCode = 404;
      return res.end("Not Found");
    }

    const headers = {};
    for (const [key, value] of Object.entries(req.headers)) {
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
      if (k.startsWith("x-vercel-")) continue;
      if (Array.isArray(value)) headers[k] = value.join(", ");
      else if (value !== undefined) headers[k] = String(value);
    }

    const opts = { method: req.method, headers, redirect: "manual" };
    if (req.method !== "GET" && req.method !== "HEAD") {
      opts.body = Readable.toWeb(req);
      opts.duplex = "half";
    }

    const upstream = await fetch(TARGET_BASE + upstreamPath + url.search, opts);
    res.statusCode = upstream.status;
    upstream.headers.forEach((value, key) => {
      if (!["connection", "transfer-encoding"].includes(key.toLowerCase())) {
        res.setHeader(key, value);
      }
    });
    if (!upstream.body) return res.end();
    Readable.fromWeb(upstream.body).pipe(res);
  } catch {
    res.statusCode = 502;
    res.end("Bad Gateway");
  }
}
