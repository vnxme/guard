# BGP Guard

**BGP Guard** is a [BIRD](https://bird.network.cz/) route server that publishes the IP prefixes of popular services and countries over BGP, tagged with large communities. Your router peers with it, picks the groups it needs by community, and routes that traffic however you like, for example through a VPN tunnel. The app is distributed as a Docker image.

- Prefixes of 30+ services (Google, Microsoft, Amazon, Cloudflare, Telegram, …) grouped by the AS numbers they announce from
- Prefixes of countries, selectable from the full ISO 3166-1 list
- Updated automatically every 24 hours from [ipverse](https://github.com/ipverse)
- A prefix that belongs to several groups is sent once, carrying the communities of all of them
- A web looking glass ([bird-lg-go](https://github.com/xddxdd/bird-lg-go)) to browse the routes

## Quick start

```sh
docker run -d --name guard --restart unless-stopped \
  -p 80:80 -p 179:179 \
  -e BIRD_ASN=65000 -e BIRD_IP=203.0.113.10 \
  vnxme/guard
```

The image is also published as `ghcr.io/vnxme/guard`. On start the container downloads the prefix lists and loads them into BIRD; until that finishes, peers receive no routes. Open `http://<host>/` to see the looking glass.

> [!WARNING]
> BGP sessions are accepted from **any** address and any AS number other than your own. Peers cannot inject routes (all imports are rejected), but anyone who reaches port 179 receives the full feed. Restrict access with a firewall if the feed should not be public.

## Environment variables

| Variable   | Default      | Description                        |
|------------|--------------|------------------------------------|
| `BIRD_ASN` | `65000`      | Local AS number                    |
| `BIRD_IP`  | `1.2.3.4`    | Router ID, in IPv4 address format  |

The container refuses to start if a value is not a valid AS number or router ID.

## Peering

The server waits for peers to connect (passive, multihop eBGP). An IPv4 session receives IPv4 routes, an IPv6 session receives IPv6 routes. The server's AS number must differ from yours. Graceful restart is enabled, so a router that supports it keeps the routes for up to 120 seconds while the container restarts.

Example for a BIRD client that only takes Google and Russia prefixes:

```
protocol bgp guard {
	local as 65100;
	neighbor 203.0.113.10 as 65000;
	multihop;
	ipv4 {
		import where (65000, 10, 240) ~ bgp_large_community || (65000, 11, 643) ~ bgp_large_community;
		export none;
	};
}
```

The routes' next hop is the server itself, so in practice your import filter should also point them at your tunnel or gateway.

## Communities

Routes carry [large communities](https://www.rfc-editor.org/rfc/rfc8092) in the form `(ASN, tag, value)`, where `ASN` is `BIRD_ASN` (32-bit AS numbers work). The values below assume the default `BIRD_ASN=65000`.

| Community                     | Meaning |
|-------------------------------|---------|
| `65000:0:<AS number>`         | Origin AS number of a route from an AS group, e.g. `65000:0:15169` |
| `65000:1:<country ID>`        | Origin country of a route from a country or a group of countries: the ID of that country's own line in [iso.mapping.txt](bird/iso.mapping.txt), enabled or commented out, e.g. `65000:1:643` Russia, or `65000:1:276` Germany via EU27 |
| `65000:10:<AS group ID>`      | AS group, ID from [as.mapping.txt](bird/as.mapping.txt), e.g. `65000:10:240` Google |
| `65000:11:<country group ID>` | Country or group of countries, ID from [iso.mapping.txt](bird/iso.mapping.txt), e.g. `65000:11:643` Russia, `65000:11:1000` EU27 |
| `65000:10:100`                | Custom static route (see [Custom routes](#custom-routes)) |
| `65000:<provider AS>:0`       | Route from an [upstream BGP feed](#upstream-bgp-feeds), e.g. `65000:65432:0`; looking glass only |

### AS groups

| ID  | Group          | ID  | Group          | ID  | Group          |
|-----|----------------|-----|----------------|-----|----------------|
| 110 | Akamai         | 220 | Frantech       | 330 | OpenAI         |
| 120 | Amazon         | 230 | Gcore          | 340 | Oracle         |
| 130 | Cloudflare     | 240 | Google         | 350 | OVH            |
| 140 | Clouvider      | 250 | Hetzner        | 360 | Scalaxy        |
| 150 | Constant_Vultr | 260 | IBM_Cloud      | 370 | Scaleway       |
| 160 | Contabo        | 270 | Iomart         | 380 | Telegram       |
| 170 | Creanova       | 280 | M247           | 390 | Twitter        |
| 180 | Datacamp_CDN77 | 290 | Melbicom       | 400 | Youtube        |
| 190 | DigitalOcean   | 300 | Microsoft      | 410 | Zenlayer       |
| 200 | Facebook       | 310 | Mullvad        |     |                |
| 210 | Fastly         | 320 | Netflix        |     |                |

The Microsoft group includes its subsidiaries (GitHub, LinkedIn, Skype, Activision Blizzard, ZeniMax). The YouTube AS numbers are only in the YouTube group, not in Google.

### Countries

Enabled by default: Belarus (112), Kazakhstan (398), Russia (643), Ukraine (804). All other countries are listed in [iso.mapping.txt](bird/iso.mapping.txt) and commented out.

A line may list several countries, which makes a group sent under one ID. The file ends with commented-out groups: EU27 (1000), EEA (1001), Schengen (1002), CIS (1003), Nordic (1004) and Baltic (1005). A prefix of a country that is also enabled on its own carries both IDs.

## Customization

Configuration lives in `/etc/bird` inside the container; the defaults are in the [bird](bird/) directory of this repository. Replace any file by mounting your own version over it.

### Groups and countries

```sh
docker run … \
  -v ./as.mapping.txt:/etc/bird/as.mapping.txt:ro \
  -v ./iso.mapping.txt:/etc/bird/iso.mapping.txt:ro \
  vnxme/guard
```

Both files have one group per line, `ID Name items`:

```
# ID  Name      AS numbers (as.mapping.txt) or ISO alpha-2 codes (iso.mapping.txt)
240 Google 15169,36040,396982
643 Russia RU
# 392 Japan JP   <- disabled
```

- `#` starts a comment, either on its own line or after an entry.
- `Name` may only contain letters, digits and `_`, and must be unique across both files, ignoring case (`Google` and `google` clash).
- IDs are numbers from 0 to 4294967295; `100` in `as.mapping.txt` is taken by custom static routes.
- Items are separated by commas without spaces; AS numbers are from 1 to 4294967295.
- IDs in `iso.mapping.txt` are by convention the ISO 3166-1 numeric codes for single countries, and 1000 or higher for groups of countries.

Changes are applied on the next update, or immediately after `docker restart guard`. If a line breaks these rules, the update stops with an error naming the file and line, and the routes already loaded stay in place.

### Custom routes

Files named `*.ipv4.generic.conf` and `*.ipv6.generic.conf` in `/etc/bird/static.conf.d/` are loaded as extra routes tagged `65000:10:100`:

```
route 198.51.100.0/24 unreachable;
```

A route may also set its origin AS number or country ID, which adds the matching `65000:0:…` or `65000:1:…` community:

```
route 198.51.100.0/24 unreachable { asn_origin = 64500; };
route 203.0.113.0/24 unreachable { geo_origin = 276; };
```

The prefixes above are documentation ranges, which the server filters out like other bogons; use real prefixes.

### Upstream BGP feeds

The files in [bgp.conf.d](bird/bgp.conf.d/) open sessions to these providers:

| File       | Provider                                                      | AS number | Neighbor         | Tables          |
|------------|---------------------------------------------------------------|-----------|------------------|-----------------|
| `afd.conf` | [antifilter.download](https://antifilter.download)            | 65432     | 45.154.73.71     | `afd4`, `afd6`  |
| `afn.conf` | [antifilter.network](https://antifilter.network)              | 65444     | 51.75.66.20      | `afn4`, `afn6`  |
| `ref.conf` | [Re-filter](https://github.com/1andrevich/Re-filter-lists)    | 65412     | 165.22.127.207   | `ref4`, `ref6`  |

Their routes are kept in separate tables that you can browse in the looking glass; they are not passed on to your peers. Each route keeps the provider's own communities (listed at the top of each file) and gets `65000:<provider AS>:0`.

Mount an empty file over one to disable it. To add a provider, copy one of the files, replace its suffix (`afd`, `afn` or `ref`) throughout with a new one, and set `asn_*` and `ip4_*` at the top to the provider's AS number and address.

## How it works

The container runs [supervisord](http://supervisord.org/) with four programs:

| Program    | Role                                                                                  |
|------------|---------------------------------------------------------------------------------------|
| `bird`     | The BGP server                                                                        |
| `updater`  | Every 24 hours runs [ipverse.sh](bird/ipverse.sh), which downloads the prefix lists and generates BIRD config, then reloads BIRD; retries every 5 minutes on failure |
| `proxy`    | Looking glass backend, talks to BIRD (listens on `127.0.0.1:8000` only)               |
| `frontend` | Looking glass web interface on port 80                                                |

The looking glass programs are both built from the [vnxme/bird-lg-go](https://github.com/vnxme/bird-lg-go/tree/fix-truncated-routes) fork (branch `fix-truncated-routes`).

[bgptools.sh](bird/bgptools.sh) is an alternative generator for the AS groups that uses the [bgp.tools](https://bgp.tools) routing table instead of ipverse. It reads only `as.mapping.txt`, so it does not produce the country groups, and it is included but not run by default.

All logs go to `docker logs`. The Docker health check reports whether BIRD is responding.

## Image tags

| Tag                     | Built from                                  |
|-------------------------|---------------------------------------------|
| `latest`                | The newest release                          |
| `1.2.3`, `1.2`, `1`     | Release `v1.2.3` (and the newest `1.2.x` / `1.x`) |
| `main`                  | The newest commit on `main`                 |
| `weekly`                | Weekly rebuild of `main` with updated base image and packages |
| `sha-<commit>`          | A specific commit                           |

Images are built for `linux/amd64`, `linux/arm64`, `linux/arm/v7` and `linux/386`.

## Building

```sh
docker build -t guard .
```
