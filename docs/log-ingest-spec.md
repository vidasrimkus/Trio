# Log ingest — contract between Trio `LogShipper` and t1d-monitor

Status: implemented on the Trio side (`Trio/Sources/Services/LogShipper/`, branch `feature/log-shipper`).
The server side is built in `t1d-monitor` against this document. If anything here changes, both sides change.

## 1. What the phone sends

Trio runs on the child's phone. After every loop cycle (≈ 5 min; fallback: after every glucose store) it reads
the **new bytes** of two log files and POSTs them. Off by default; enabled in Trio → Settings → Support &
Community → Log Shipper (URL + Bearer token, both kept in the iOS Keychain).

| Stream | File on the phone (`Documents/`) | Writer | Line format |
|---|---|---|---|
| `trio` | `logs/log.txt`, rotated daily to `logs/log_prev.txt` | `SimpleLogReporter` | `2026-11-01T00:02:20+0200 [Category] File.swift - function - line - DEV: message` |
| `dana` | `danakit/dana_log.txt`, rotated daily to `danakit/dana_log_prev.txt` | DanaKit `DanaLogWriter` | `[2026-11-01T00:02:21+0200 INFO] File.swift - function#line: message` |

Facts the server must live with:

- **Entries span lines.** Both logs contain multi-line entries (Dana state dumps `* key: value`, Trio error
  descriptions). A batch is cut at a `\n`, never inside a line, but it may end in the middle of a multi-line entry;
  the next batch continues it. Split entries by timestamp prefix, not by line.
- **Levels.** Trio: `DEV` (98 %), `INFO`, `WARN`, `ERR`. Dana: `DEBUG` (≈ 94 % of lines), `INFO`, `WARNING`, `ERROR`.
- **Volume** (measured 2026-11-01, Dana connected): 11.6 MB/day Trio (41.9 k lines), 19.3 MB/day Dana (143.8 k lines);
  ≈ 31 MB/day raw, ≈ 2.9 MB/day compressed as 5-minute batches. Per shipment compressed: median 9 KB, p99 22 KB,
  max 29 KB; raw max ≈ 620 KB. With Omnipod DASH the `dana` stream simply stops.
- **Timestamps are phone-local with offset** (`+0200`/`+0300`). Store as received and index by the parsed UTC instant.
- **Clock skew.** `sent_at` is the phone's clock; the server records its own `received_at` too.

## 2. HTTP

```
POST /api/logs
Host: logs.<domain>            (own hostname through cloudflared, no Cloudflare Access on it — §7)
Authorization: Bearer <token>
Content-Type: application/json
Content-Encoding: deflate-raw
X-Trio-Log-Encoding: deflate-raw
```

- The body is **raw DEFLATE (RFC 1951)** of the UTF-8 JSON — what Apple's `NSData.compressed(using: .zlib)`
  produces: no zlib header, no checksum. Node: `zlib.inflateRawSync(body)`. Do not use a body parser that
  interprets `Content-Encoding`; read the raw bytes. Treat the request as deflate-raw when **either** header says so
  (a proxy may strip one).
- Request timeout on the phone is 15 s. Answer fast; do analysis after responding.
- One request in flight per phone at a time. Normal cadence one per ≈ 5 min; during catch-up one per cycle with
  up to 1 MB raw per stream.

### 2.1 Body

```json
{
  "v": 1,
  "install_id": "4b1e…-lowercase-uuid",
  "app": { "version": "1.0.1", "build": "2", "sha": "3943384b8" },
  "sent_at": "2026-11-02T08:15:00Z",
  "batches": [
    {
      "stream": "trio",
      "file_id": "1234567:1761948000",
      "from": 123456,
      "to": 234567,
      "gap_before": false,
      "text": "2026-11-02T10:10:02+0200 [ApsManager] …\n…\n"
    }
  ]
}
```

JSON Schema (draft 2020-12):

```json
{
  "type": "object",
  "required": ["v", "install_id", "app", "sent_at", "batches"],
  "additionalProperties": false,
  "properties": {
    "v": { "const": 1 },
    "install_id": { "type": "string", "pattern": "^[0-9a-f-]{36}$" },
    "app": {
      "type": "object", "required": ["version", "build", "sha"],
      "properties": { "version": {"type":"string"}, "build": {"type":"string"}, "sha": {"type":"string"} }
    },
    "sent_at": { "type": "string", "format": "date-time" },
    "batches": {
      "type": "array", "minItems": 1, "maxItems": 2,
      "items": {
        "type": "object",
        "required": ["stream", "file_id", "from", "to", "gap_before", "text"],
        "additionalProperties": false,
        "properties": {
          "stream": { "enum": ["trio", "dana"] },
          "file_id": { "type": "string", "pattern": "^[0-9]+:[0-9]+$" },
          "from": { "type": "integer", "minimum": 0 },
          "to": { "type": "integer", "minimum": 1 },
          "gap_before": { "type": "boolean" },
          "text": { "type": "string" }
        }
      }
    }
  }
}
```

Semantics:

- `install_id` — random UUID per app install (survives updates, not reinstalls). One phone = one id; keep a small
  allow-list or just record it.
- `file_id` = `<inode>:<creation date, unix seconds>` of the log file on the phone. It survives the daily rename
  (`log.txt` → `log_prev.txt`) and changes for every fresh file. One `file_id` ≈ one day of one stream.
- `from`/`to` — **raw byte offsets** in that file (before redaction). `to - from` can differ from `text.length`
  because redaction and UTF-8 repair change the text, never the offsets. `to > from` always.
- `gap_before: true` — bytes before `from` in this stream were lost (missed rotation, truncated file, phone reinstalled).
  Record it; it explains a hole, it is not an error.
- Batches for different streams in one request are independent. At most one batch per stream per request.

### 2.2 Responses

| Status | Body | Phone's reaction |
|---|---|---|
| `200` | `{"accepted":[{"stream":"trio","file_id":"1234567:1761948000","to":234567}]}` — one entry per batch the server stored **or already had** (§2.3) | Offset moves to `to` (capped at the batch's own `to`). A batch missing from `accepted` is re-sent next time. **A 2xx that names none of the sent batches is treated like a `5xx`** (backoff, visible error): never answer 2xx with an empty `accepted` to a request that carried batches — reject it with a 4xx/5xx instead. |
| `401`, `403` | any | Shipping **pauses** until the settings are saved again on the phone. Rotate the token only together with the phone. |
| `413` | any | Batch limit halves (1 MB → … → 64 KB floor), retry next cycle. Answer 413 when the raw body or the inflated JSON exceeds the limits in §4. |
| `429`, `5xx`, anything else | optional `Retry-After: <seconds>` | Backoff 5 → 10 → 20 → 40 → 60 min (or `Retry-After`, capped at 3600). Nothing is lost: the log files are the buffer. |

Always answer JSON on 200. On error a plain body is fine. The phone never shows an error to the child; status is
visible only in the Log Shipper screen.

### 2.3 Delivery guarantees and deduplication

At-least-once. The same `(install_id, stream, file_id, from)` can arrive twice (timeout after the server stored it;
phone restarted). Server rule:

1. Key = `(install_id, stream, file_id, from)`. A duplicate key with the same `to` → answer `accepted` again, store nothing.
2. Overlap: new `from` < stored `to` for the same `file_id` → keep only the part from the stored `to` onwards
   (byte offsets are exact; find the matching cut by `to - from` on the raw length, which is what the phone counts — if
   text and offsets disagree because of redaction, keep the whole batch and mark `overlap=1` rather than guess).
3. Always answer `accepted` with the phone's `to` for anything you stored or already had.

## 3. Redaction (done on the phone; server does not need to repeat it, but may assert it)

`LogRedactor` runs over the decoded text of every batch:

| Always | Replacement |
|---|---|
| Dana keys in every form DanaKit logs them: `pairingKey: <hex>`, `Pairing key: <hex>`, `random pairing key: <hex>`, `random sync key: <n>` (DanaKit e157a86 `PeripheralManager.swift` 328, 383, 414; case-insensitive) | `…: [redacted]` |
| `Sending pairing request … Data: <hex>`, `Sending Passkey check … Data:`, `Passkey request failed … Data:` | `Data: [redacted]` |
| `Device token updated: <APNS token>` | `[redacted]` |
| `token=`, `secret=`, `api-secret=`, `api_secret=`, `password=`, `passkey=`, `pin=` values (query strings, case-insensitive) | `=[redacted]` |
| `Authorization: Bearer <x>` / `Bearer <x>` (≥ 8 chars) | `Bearer [redacted]` |

Around a pairing line (`Sending pairing request`, `processPairingRequest`, `Passkey`, `requesting pincode`,
`Requested pincode`, `security keys`; not the per-connect `Setting encryption keys` line, whose key values are redacted
on their own) — 20 lines before it and 150 lines after it — every packet
dump (`Data: <hex>`, `Receiving data: <hex>`, `Encoded data: <hex>`, `decrypt data: <hex>`; case-insensitive) becomes
`…data: [redacted:pairing]`; the rest of the batch keeps its packets. Residual risk: a pairing split across two
batches lets the second batch's first packets through; acceptable for our own server.

Not redacted (needed for diagnostics): Nightscout host in URL errors, Dana `deviceName`/`bleIdentifier`, glucose and doses.
The content is the child's health data — treat the whole store as sensitive (§5).

## 4. Limits the server enforces

| What | Limit | Response |
|---|---|---|
| Compressed body | 2 MB | 413 |
| Inflated JSON | 16 MB | 413 (stop inflating at the limit) |
| `text` per batch | 1 MB + 10 % slack | 413 |
| Batches per request | 2 | 400 |
| Requests per install | 60 / 5 min (catch-up bursts are 1 per cycle, so this is generous) | 429 + `Retry-After` |
| Unknown `install_id` | configurable: accept-and-record (default) or 403 | — |
| Bearer compare | `crypto.timingSafeEqual` against the SHA-256 of the token stored in config | 401 |

## 5. Storage

- Raw: `/opt/t1d-monitor/data/logs/<install_id>/YYYY-MM-DD/<stream>.log.gz`, **one gzip member appended per batch**
  (so `zcat` reads the day as one file). Day = phone-local date from the batch's first timestamp (fall back to UTC
  `received_at`). Permissions `0600`, service user `t1d`, `UMask=0077` like the other services. Retention 90 days
  (≈ 260 MB).
- SQLite `t1d.db`, table `log_batches(id, install_id, stream, file_id, from_offset, to_offset, gap_before, bytes_raw,
  bytes_text, first_ts, last_ts, received_at, sent_at, overlap)`; unique `(install_id, stream, file_id, from_offset)`.
- SQLite `log_events(id, install_id, stream, ts, level, category, kind, line, batch_id)`: only the lines worth keeping
  forever (no retention), extracted while ingesting — §6.

## 6. What is extracted into `log_events` and analysed at once

Match on the **message part** of each entry. `kind` is the first matching rule; `line` is the whole first line
of the entry (max 2 KB).

| Stream | `kind` | Match |
|---|---|---|
| trio | `trio_event` | lines containing `[trio-event v1]` (§6.1) — these also arrive as Nightscout Notes |
| trio | `warn` / `err` | `- WARN: ` / `- ERR: ` level |
| trio | `loop_failed` | `Loop failed with error:` |
| trio | `bolus_failed` | `Bolus failed with error:` or `Bolus cancellation failed` |
| trio | `bolus_enact` | `Enact bolus ` (amount and manual/SMB — pairs with `bolus_failed`) |
| trio | `bolus_deleted_local` | `Successfully deleted the treatment object.` and any line containing `deleteInsulin` (`deleteInsulinFromNightscout`, `deleteInsulinFromServices`, `NightscoutManager … deleteInsulin`) — the local trace of a History deletion, kept so a deletion is visible even when the Nightscout Note failed |
| trio | `bg_task_expired` | `ended in expiration handler` |
| dana | `error` / `warning` | `ERROR]` / `WARNING]` level |
| dana | `pump_check_error` | `PUMP_CHECK error`, `wrong serial number`, `Invalid BLE-5 keys`, `Invalid password`, `Requested pincode` |
| dana | `disconnect` | `Device disconnected` |
| dana | `no_connection` | `noConnection` |
| dana | `bolus` | `Bolus`/`bolus` lines at INFO level and above |

Immediate analysis (feed the existing Telegram path; rule file `collector/src/alerts/rules/trio-logs.js` or similar):

1. `bolus_failed`, `loop_failed` ≥ 3 in 30 min, `pump_check_error` — alert at once (dedupe 30 min per kind).
2. `trio_event` lines (`bolus_deleted`, `bolus_failed`, `pump_error`) — alert at once if the same event did **not**
   already arrive as a Nightscout Note (the Note path is the primary one; the log is the backup). Match on the full note text.
3. `disconnect` count per hour above a threshold learned from the first week (2026-11-01 had 514/day).
4. `gap_before = true` — one Telegram line per gap.
5. **No shipment for 30 min while the collector sees fresh devicestatus** → "Trio loops but logs do not arrive"
   (shipper or network/auth problem). No shipment and no devicestatus → leave it to `loop-stale`, do not double-alert.

### 6.1 `[trio-event v1]` — Note / log line grammar

Produced by `TrioEventNote.format` and sent both as a Nightscout Note (`eventType: "Note"`, `enteredBy: "Trio"`)
and as a `DEV:` line in the trio log.

```
[trio-event v1] bolus_deleted id=<pump event id> amount=<U, decimal> kind=smb|manual|external [delivered=true|false] at=<ISO-8601 UTC, seconds>
[trio-event v1] bolus_failed kind=manual [err="<text>"]
[trio-event v1] pump_error err="<text>"
```

- Fields are space-separated `key=value`; only `err` is quoted. `err` text is one line, `"` replaced by `'`, at most 120
  characters (ends with `…` when cut).
- `bolus_deleted`: `delivered=true` when the pump record was final (`PumpEventStored.isMutable == false`),
  `delivered=false` when it was still pending; the field is absent for external insulin. `at` is the bolus timestamp,
  not the deletion time (the Note's `created_at` is the deletion time).
- `bolus_failed kind=manual` comes from `BolusFailureObserver` (manual boluses only, including "pump suspended/bolusing"
  pre-checks). `pump_error` covers every other `APSManager.lastError` (loop failures, SMB failures, cancel failures),
  at most once per 30 min for the same text. An SMB failure therefore appears as `pump_error`; the amount is in the
  log (`Enact bolus` / `Bolus failed with error`) a few minutes later.
- Parse with: `^\[trio-event v(\d+)\] (\w+)((?: \w+=(?:"[^"]*"|\S+))*)$`.

## 7. Exposure through Cloudflare

Decision: **own hostname** `logs.<domain>` as an extra ingress in the existing `cloudflared` config → `http://127.0.0.1:3020`,
**no Access application** on it, only `POST /api/logs` (everything else 404), rate limit per §4.

- Check that no wildcard Access application (`*.<domain>`) covers the new hostname.
- Check that Bot Fight Mode / managed challenges do not act on this hostname (the phone cannot solve a challenge);
  add a WAF skip rule for the hostname if needed.
- Cloudflare's own upload limit (100 MB free plan) is far above §4.
- Rejected: service token (two more secrets on the phone, silent stop when it expires); path bypass on the UI
  hostname (one policy mistake opens the UI).

Service: separate systemd unit `t1d-logs-ingest` (same hardening as `t1d-collector.service`), listening on
`127.0.0.1:3020`, config in `collector/config.json` → `logs: { port, tokenSha256, dataDir, retentionDays, installIds }`.

## 8. Test aids

Node snippet producing a valid request body:

```js
const zlib = require("zlib");
const body = zlib.deflateRawSync(Buffer.from(JSON.stringify({
  v: 1, install_id: "11111111-1111-1111-1111-111111111111",
  app: { version: "1.0.1", build: "2", sha: "3943384b8" },
  sent_at: new Date().toISOString(),
  batches: [{ stream: "trio", file_id: "1:1761948000", from: 0, to: 12, gap_before: false,
              text: "2026-11-02T10:10:02+0200 [Service] LogShipper.swift - f - 1 - DEV: hello\n" }],
})));
// curl --data-binary @body.bin -H 'Content-Encoding: deflate-raw' -H 'Content-Type: application/json' -H 'Authorization: Bearer …' https://logs.<domain>/api/logs
```

Phone-side unit tests (`TrioTests/LogShipperTests.swift`) pin: offset/rotation/gap logic, every redaction rule, the Note
grammar, the wire format keys, the response-to-outcome mapping and the backoff ladder.
