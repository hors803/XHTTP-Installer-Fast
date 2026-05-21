# XHTTP Installer Fast Relay

One-click installer for Debian/Ubuntu servers that deploys Xray VLESS + XHTTP + TLS and prepares a lightweight CDN relay.

Supported relay modes:

- Vercel: deployed by REST API. No Vercel CLI is installed on the VPS.
- Netlify: generates Git/manual deploy files. No Node.js, npm, or Netlify CLI is installed on the VPS.

## One-Line Install

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/hors803/XHTTP-Installer-Fast/main/install.sh)
```

For Vercel:

```bash
VERCEL_TOKEN='your_vercel_token' bash <(curl -fsSL https://raw.githubusercontent.com/hors803/XHTTP-Installer-Fast/main/install.sh)
```

For Netlify Git/manual deploy:

```bash
XHTTP_RELAY_HOST='your-site.netlify.app' bash <(curl -fsSL https://raw.githubusercontent.com/hors803/XHTTP-Installer-Fast/main/install.sh)
```

## VPS Requirements

- Debian 12+ or Ubuntu 20.04+
- Root access
- A domain A record pointing to the VPS IPv4
- TCP 443 open
- TCP 80 recommended for Let's Encrypt HTTP-01 issuance/renewal

## What The VPS Installs

- Xray-core
- acme.sh
- Basic system tools such as curl, jq, openssl, socat, dnsutils

The fast installer does not install provider CLIs.

## Vercel Flow

Choose platform `1`.

The installer:

1. Configures Xray VLESS + XHTTP + TLS on the VPS.
2. Renders the Vercel relay template.
3. Deploys the relay to Vercel through the Vercel REST API.
4. Prints the final VLESS link.

## Netlify Flow

Choose platform `2`.

The installer:

1. Configures Xray VLESS + XHTTP + TLS on the VPS.
2. Generates a Netlify relay project under `/opt/xhttp-relay-fast/netlify`.
3. Generates `/opt/xhttp-relay-fast/netlify-relay.zip`.
4. Prints the VLESS link using `XHTTP_RELAY_HOST`.

Deploy the generated Netlify project through GitHub/Netlify UI. The VPS does not run Netlify CLI.

## Important Path Rules

The installer generates two different paths:

- `Server XHTTP path`: used only between relay and VPS.
- `Relay public path`: used by the client.

The client must use the relay domain and the public path. It must not use the VPS domain or server path directly.

## Source IP Headers

The relay templates filter common client IP forwarding headers before sending traffic to Xray:

- `forwarded`
- `x-forwarded-for`
- `x-real-ip`
- `client-ip`
- `true-client-ip`
- `cf-connecting-ip`

This prevents Xray access logs from recording the real client IP when the request passes through the relay provider.

## Management

After installation:

```bash
xhttp
xhttp link
xhttp status
xhttp logs
xhttp restart
```

## Verify

The relay root path should return:

```text
OK
```

Wrong paths should return:

```text
Not Found
```

A raw `curl -d test` request to the XHTTP path may return an empty 404 from Xray. That is expected because it is not valid VLESS/XHTTP traffic.
