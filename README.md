# lately

Nim SDK for the **Late.dev** API (https://getlate.dev).

This repo primarily provides the `lately` library (an async Nim client for Late’s REST API), and also contains an **experimental CLI** (`gld`) under `src/gld/`.

---

## Contents

- [Install](#install)
- [Requirements](#requirements)
- [Authentication](#authentication)
- [Using the SDK](#using-the-sdk)
  - [Response style: `Raw` vs typed](#response-style-raw-vs-typed)
  - [Quick start: list profiles](#quick-start-list-profiles)
  - [Accounts: list + health](#accounts-list--health)
  - [Queue: slots, preview, next slot](#queue-slots-preview-next-slot)
  - [Media: presign + upload](#media-presign--upload)
  - [Posts: create, list, update, delete, retry](#posts-create-list-update-delete-retry)
  - [Webhooks: settings + logs + test](#webhooks-settings--logs--test)
  - [Tools: downloads (X/Twitter, Instagram, etc.)](#tools-downloads-xtwitter-instagram-etc)
  - [Platform settings helpers (advanced)](#platform-settings-helpers-advanced)
- [Tests](#tests)
- [Module map](#module-map)
- [Experimental: `gld` CLI](#experimental-gld-cli)
- [Development notes](#development-notes)

---

## Install

```bash
nimble install lately
```

Then:

```nim
import lately
```

---

## Requirements

- Nim `>= 2.0.8` (see `lately.nimble`)
- HTTPS support: compile/run with `-d:ssl` (recommended for all API calls)

Library dependencies:

- `rz` (result type used by the typed wrappers)
- `jsony` (fast JSON (de)serialization)
- `ic` (optional debug helpers used throughout the repo)

---

## Authentication

All endpoints require a Late.dev API key.

In this repo/examples, the key is typically passed as a string argument called `api_key` and sent as:

- `Authorization: Bearer <api_key>`

---

## Using the SDK

### Response style: `Raw` vs typed

Most endpoints come in two flavors:

- `*Raw` procs return the raw JSON response as a `string`.
- Typed procs return `Future[rz.Rz[T]]` where `T` is a Nim object representing the response shape.

The typed procs use `jsony` to decode JSON and wrap the result in `rz`:

- `res.isErr` / `res.err`
- `res.isOk` / `res.val`

---

### Quick start: list profiles

```nim
import std/[asyncdispatch]
import lately

const api_key {.strdefine.} = ""

when isMainModule:
  if api_key.len == 0:
    quit("Pass -d:api_key=...", 1)

  let res = waitFor listProfiles(api_key, includeOverLimit = true)
  if res.isErr:
    quit(it.err, 1)

  for p in res.val.profiles:
    echo p.name, "  id=", p.id
```

Run:

```bash
nim r -d:ssl -d:api_key=... path/to/your_example.nim
```

---

### Accounts: list + health

```nim
import std/[asyncdispatch, options]
import lately/accounts

let listRes = waitFor listAccounts(
  api_key = api_key,
  profileId = none string,
  includeOverLimit = true
)

let healthRes = waitFor accountsHealth(
  api_key = api_key,
  profileId = none string
)
```

Useful endpoints in `lately/accounts`:

- `listAccounts`, `listAccountsRaw`
- `accountsFollowerStats`, `accountsFollowerStatsRaw`
- `accountsHealth`, `accountsHealthRaw`
- `accountHealth`, `accountHealthRaw`
- `updateAccount`, `disconnectAccount`

---

### Queue: slots, preview, next slot

```nim
import std/[asyncdispatch, options]
import lately/queue

let slots = waitFor getQueueSlots(api_key, profileId)
let preview = waitFor previewQueue(api_key, profileId, count = some 5)
let next = waitFor nextSlot(api_key, profileId)

# helper for defining slots:
let mondayAt10 = qSlot(Monday, "10:00")
```

Conveniences in `lately/queue`:

- `qSlot(day, "HH:MM")`
- Day constants: `Sunday..Saturday` (0..6)

---

### Media: presign + upload

There are three common patterns:

1) Presign only (`mediaPresign`)
2) Upload to a presigned URL (`mediaUploadToPresignedUrl`)
3) Convenience: presign + upload (`mediaUploadFile`) → returns the final `publicUrl`

```nim
import std/[asyncdispatch]
import lately/media

let publicUrlRes = waitFor mediaUploadFile(api_key, "./my_image.jpg")
if publicUrlRes.isErr:
  quit(it.err, 1)

echo "publicUrl: ", publicUrlRes.val
```

Notes:

- Upload helpers currently read the whole file into memory before PUT-ing. Keep that in mind for very large files.

---

### Posts: create, list, update, delete, retry

Create a post uses `lately/models` for `mediaItem` and `platform` types.

```nim
import std/[asyncdispatch, options]
import lately/[posts, models]

let mediaItems = @[ miImage("https://example.com/img.png", "img.png") ]

let platforms = @[ platform(platform: "twitter", accountId: "<accountId>") ]

let created = waitFor createPost(
  api_key     = api_key,
  content     = some "Hello from Nim",
  mediaItems  = mediaItems,
  platforms   = platforms,
  publishNow  = some true,
  timezone    = some "UTC"
)

if created.isErr:
  quit(it.err, 1)

echo "postId: ", created.val.post.id
```

Other operations in `lately/posts`:

- `listPosts`, `getPost`
- `updatePost` (PATCH via a JSON body)
- `deletePost`
- `retryPost`

---

### Webhooks: settings + logs + test

```nim
import std/[asyncdispatch, options]
import lately/webhooks

let hooks = waitFor webhooksList(api_key)
let logs  = waitFor webhooksLogs(api_key, limit = some 20)
```

Webhooks support:

- list/create/update/delete settings
- send a test webhook
- fetch delivery logs

---

### Tools: downloads (X/Twitter, Instagram, etc.)

`lately/downloads` exposes “download tools” endpoints for various platforms.

```nim
import std/[asyncdispatch]
import lately/downloads

let body = waitFor twitterDownloadRaw(api_key, "https://x.com/...")
echo body
```

It also includes convenience procs like `twitterDownloadTo(...)` that download the returned URL to a local file.

---

### Platform settings helpers (advanced)

`lately/models` includes helper constructors for `platformSpecificData` for certain platform-specific settings.

Examples:

- `pTwitterThread(accountId, threadItems, firstComment)`
- `pIGReel(...)`, `pIGStory(...)`
- `pLinkedIn(...)`, `pPinterest(...)`, `pYouTube(...)`
- `pTelegram(...)`, `pTiktok(...)`

These helpers are useful when you need structured per-platform settings in the `platforms` array sent to `createPost`.

---

## Tests

Tests are in `tests/test.nim` and are **integration tests** (they call the real API).

They require:

- `api_key` (Late API key)
- `profileId` (a Late profile id)

Run:

```bash
nim r -d:ssl -d:api_key=... -d:profileId=... tests/test.nim
```

There is also a local convenience flag used by the author:

```bash
nim r -d:ssl -d:use_keys tests/test.nim
```

That path imports `mynimlib/keys` (not part of this repo), so it may not work in your environment.

What the test suite does:

- Exercises queue endpoints (including create/update/delete queue)
- Uploads `tests/test.jpg` and an mp4 in `tests/`
- Exercises downloads endpoints for a few sample URLs
- Creates/updates/deletes a profile (best-effort)

If you don’t want tests to create/delete resources on your account, review `tests/test.nim` before running.

---

## Module map

You can import everything via the umbrella module:

```nim
import lately
```

Or individual endpoints:

```nim
import lately/[accounts, downloads, media, models, posts, profiles, queue, webhooks]
```

High-level overview:

- `lately/accounts` – connected accounts, follower stats, account health
- `lately/profiles` – profile CRUD
- `lately/posts` – create/list/get/update/delete/retry posts
- `lately/queue` – queue schedules, preview, next slot, helper `qSlot`
- `lately/media` – presign + upload helpers
- `lately/webhooks` – webhook configuration + logs
- `lately/downloads` – Late “tools/downloads” endpoints
- `lately/models` – shared enums/types + platform-specific helpers

---

## Experimental: `gld` CLI

This repo contains an **experimental** terminal UI CLI at:

- `src/gld/gld.nim` (entry point)
- `src/gld/src/*` (commands, config storage, interactive mode)

### Build / run locally

From the repo root:

```bash
nim c -d:ssl -r src/gld/gld.nim
```

The CLI supports both:

- `gld` (no args) → interactive wizard
- `gld init` → store API key + default profile
- `gld post`, `gld queue`, `gld accounts`, `gld profiles`, `gld uploads`, `gld sched`

### CLI config storage

The CLI stores config next to the built executable in a `.gld/` folder:

- `.gld/gld.config.json`
- `.gld/gld.uploads.json`

### Important note about CLI dependencies

The CLI imports packages/modules that are **not declared** in `lately.nimble` (for example `termui` and `mynimlib/utils`).

That means:

- The **SDK** (`lately`) is the supported/packaged part.
- The **CLI** may require additional local dependencies in your environment.

If you want, I can split `gld` into its own nimble package and document its dependencies properly.

---

## Development notes

- Most HTTP calls use `newAsyncHttpClient` and require TLS; use `-d:ssl`.
- Many response types use `jsony` rename hooks to map `_id` → `id`.
- If you prefer pure JSON handling, use the `*Raw` procs and parse with `std/json`.
