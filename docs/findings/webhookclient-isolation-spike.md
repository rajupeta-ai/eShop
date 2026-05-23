# Spike: WebhookClient Isolation — External Receiver vs. Orphaned Module

- **Ticket:** TICKET-004 (spike, high priority)
- **Type:** READ-ONLY investigation — no code under `src/WebhookClient` was modified or deleted.
- **Date:** 2026-05-23
- **Author:** dev-agent
- **Scope:** `src/WebhookClient`, `src/Webhooks.API`, `src/eShop.AppHost`, `eShop.slnx`, `eShop.Web.slnf`

---

## TL;DR — Classification

**(a) Intentional external-facing webhook receiver → the "unwired / isolated" findings are FALSE POSITIVES.**

WebhookClient is a sample Blazor Server **webhook subscriber/receiver**. It is fully wired into the
solution and the Aspire AppHost orchestration. It deliberately receives **inbound HTTP webhook
callbacks** from `Webhooks.API` at a URL that is **stored in a database at runtime** (`WebhookSubscription.DestUrl`),
not referenced in code. Static call-graph analysis cannot see that data-driven edge, which is exactly
why every analyzer pass reported "no inbound callers / subscriptions / triggers."

**Recommendation: KEEP. Do not remove or rewire.** Suppress/annotate the findings as false positives.

---

## 1. What WebhookClient is

`src/WebhookClient` is an ASP.NET Core **Blazor Server (Razor Components)** app (`Microsoft.NET.Sdk.Web`,
`net10.0`, root namespace `eShop.WebhookClient`). Its purpose is to demonstrate a third-party application
that **subscribes to** eShop webhooks and **receives** event callbacks. This matches the upstream
`dotnet/eShop` design, and this fork preserves that role.

Evidence:
- `src/WebhookClient/WebhookClient.csproj` — `Sdk="Microsoft.NET.Sdk.Web"`, references `eShop.ServiceDefaults`, OpenIdConnect, QuickGrid.
- `src/WebhookClient/Program.cs` — builds a web app, maps Razor components, auth endpoints, and webhook endpoints (`app.MapWebhookEndpoints()`, line 29).
- `src/WebhookClient/Components/Pages/AddWebhook.razor`, `Home/ReceivedMessages.razor`, `Home/RegisteredHooks.razor` — UI to register subscriptions and view received hooks.

---

## 2. HTTP endpoints WebhookClient exposes (inbound surface)

WebhookClient **does** expose inbound HTTP endpoints. It is not a passive library.

| Method    | Route                | Purpose | Source |
|-----------|----------------------|---------|--------|
| `OPTIONS` | `/check`             | Token-validation handshake. Echoes the `X-eshop-whtoken` header so the sender can verify ownership before granting a subscription. | `src/WebhookClient/Endpoints/WebhookEndpoints.cs:16` |
| `POST`    | `/webhook-received`  | **The actual webhook callback sink.** Receives `WebhookData`, validates the token, and persists it via `HooksRepository`. | `src/WebhookClient/Endpoints/WebhookEndpoints.cs:31` |
| `POST`    | `/logout`            | Sign-out (cookie + OIDC). | `src/WebhookClient/Endpoints/AuthenticationEndpoints.cs:12` |
| (various) | Razor component routes + `MapDefaultEndpoints` (`/health`, `/alive`) | Interactive Blazor UI and health checks. | `Program.cs:11,25` |

The two endpoints that matter for this spike are `OPTIONS /check` and `POST /webhook-received` — these are
the receiver contract a webhook **sender** calls.

---

## 3. How it is launched and wired

WebhookClient is **not** orphaned. It is a first-class member of both the solution and the orchestrator.

**Solution membership:**
- `eShop.slnx:17` → `<Project Path="src/WebhookClient/WebhookClient.csproj" />`
- `eShop.Web.slnf:18` → `"src\\WebhookClient\\WebhookClient.csproj"`

**AppHost orchestration (`src/eShop.AppHost/Program.cs`):**
- Line 65–67: registered as a launched project —
  ```csharp
  var webhooksClient = builder.AddProject<Projects.WebhookClient>("webhooksclient", launchProfileName)
      .WithReference(webHooksApi)                       // gives it http://webhooks-api
      .WithEnvironment("IdentityUrl", identityEndpoint);
  ```
- Line 94: self-referencing callback URL — `webhooksClient.WithEnvironment("CallBackUrl", webhooksClient.GetEndpoint(launchProfileName));`
- Line 100: Identity.API is told about it — `.WithEnvironment("WebhooksWebClient", webhooksClient.GetEndpoint(launchProfileName))` (OIDC redirect).
- `src/eShop.AppHost/eShop.AppHost.csproj:29` → `<ProjectReference Include="..\WebhookClient\WebhookClient.csproj" />`

So the orchestrator builds, launches, and supplies configuration to WebhookClient on every run.

---

## 4. The runtime wiring the static graph cannot see (root cause of the false positive)

The end-to-end flow is **subscription-driven**, and the inbound edge is addressed by a database value, not code:

1. **Subscribe (outbound from WebhookClient):** The UI (`AddWebhook.razor`) calls
   `WebhooksClient.AddWebHookAsync(...)` which does `POST /api/webhooks` against `http://webhooks-api`
   (`src/WebhookClient/Services/WebHooksClient.cs:5`; HTTP client base address `http://webhooks-api` set in
   `src/WebhookClient/Extensions/Extensions.cs:19`, matching the AppHost service name `"webhooks-api"`).
   The subscription payload carries the **callback URL** (e.g. WebhookClient's `…/webhook-received`) and a token.

2. **Grant handshake (Webhooks.API → WebhookClient):** Before accepting the subscription,
   `Webhooks.API` calls `GrantUrlTesterService.TestGrantUrl(...)` which sends an **`OPTIONS`** request to the
   subscriber URL with the `X-eshop-whtoken` header (`src/Webhooks.API/Services/GrantUrlTesterService.cs:14-27`).
   WebhookClient's `OPTIONS /check` endpoint echoes the token back to confirm ownership.

3. **Store:** Webhooks.API persists the subscription (`WebhookSubscription.DestUrl`, `.Token`) in `webhooksdb`.

4. **Deliver (Webhooks.API → WebhookClient):** When a domain event fires —
   `OrderStatusChangedToShippedIntegrationEvent`, `…ToPaid…`, or `ProductPriceChangedIntegrationEvent` —
   the handler retrieves matching subscriptions and calls
   `WebhooksSender.SendAll(...)` → `OnSendData(...)` which **`POST`s to `subs.DestUrl`** (the database-stored URL)
   with the token header (`src/Webhooks.API/Services/WebhooksSender.cs:13-33`;
   trigger e.g. `src/Webhooks.API/IntegrationEvents/OrderStatusChangedToShippedIntegrationEventHandler.cs:16`).
   That POST lands on WebhookClient's `POST /webhook-received`.

**Why the analyzer missed it:** the only thing pointing at WebhookClient's endpoints is
`WebhookSubscription.DestUrl` — a runtime string in `webhooksdb`. There is no compile-time call, no project
reference from `Webhooks.API` to `WebhookClient`, and no event-bus subscription declared in `WebhookClient`.
A static call/dependency graph therefore correctly sees zero inbound code edges — but that is the **intended
architecture of an external webhook receiver**, not a defect.

---

## 5. Findings addressed

The ticket frames this as "six unwired findings." In the analysis output there are **five distinct
`unwired`-category finding IDs** for WebhookClient. The lead ID is itself the "WebhookClient service isolation"
entry, so the ticket's "five IDs **plus** the service-isolation entry" double-counts that one. All five are
the same root cause and all resolve to **false positive**:

| Finding ID | Title | Verdict |
|------------|-------|---------|
| `cmph8qw0y005sqa16yhcf008y` | WebhookClient service isolation | False positive — wired via AppHost + runtime subscription |
| `cmph8qw2a006oqa16ubf5ru3r` | WebhookClient receives no inbound calls from other services | False positive — inbound POST `/webhook-received` from Webhooks.API at runtime |
| `cmph8qw0m005kqa16f8zurqiw` | WebhookClient has no inbound event subscriptions or triggers | False positive — by design; triggers arrive as HTTP, not event-bus subscriptions |
| `cmph8qw1c0062qa16jof36svh` | WebhookClient has no inbound callers or event subscriptions | False positive — caller is Webhooks.API via DB-stored `DestUrl` |
| `cmph8qw1r006cqa16g860rvgq` | WebhookClient has no inbound triggers from other services | False positive — trigger = integration-event handlers in Webhooks.API → `WebhooksSender` |

> **Note (count discrepancy):** Only five distinct `unwired` WebhookClient finding IDs exist in the analysis.
> If a sixth was intended, the most likely candidate is the related `test_quality` finding
> `cmph8qvze004qqa16k62lje24` ("No tests for module 'WebhookClient'") — that is a separate, *valid* gap
> (see §7), not an isolation/wiring issue.

---

## 6. Recommendation: **KEEP** (suppress findings as false positives)

- **Keep / do not remove:** WebhookClient is an intentional external-facing webhook receiver, fully wired
  into `eShop.slnx`, `eShop.Web.slnf`, and `eShop.AppHost`. Removing it would delete a working sample
  integration and break the documented webhook-delivery demo (the risk called out in the ticket).
- **Do not "wire" anything:** there is no wiring gap. The inbound edge is intentionally data-driven
  (runtime subscription URL). Adding a static code reference from `Webhooks.API` to `WebhookClient` would be
  architecturally wrong (it would couple the broker to one specific subscriber).
- **Action for the analyzer:** mark the five `unwired` IDs above as **false positive / by-design** (or add a
  suppression/annotation rule that excludes data-driven HTTP webhook receivers from the unwired heuristic).
  This is a recommendation only — no suppression was applied in this READ-ONLY spike.

---

## 7. Recommended follow-up (out of scope for this spike)

1. **Close the five `unwired` findings as false positives** with a pointer to this report.
2. **Optionally** add unit tests for the `OPTIONS /check` and `POST /webhook-received` handlers
   (token-valid, token-invalid, validation-disabled paths) to address the *separate* `test_quality`
   finding `cmph8qvze004qqa16k62lje24`. A test ticket already exists
   ("Add unit tests for WebhookClient inbound webhook handling"); this spike does not duplicate it.
3. **Documentation:** note in the repo README/architecture docs that WebhookClient is an external sample
   subscriber so future analysis runs interpret the zero-inbound-edge result correctly.

---

## Appendix — Evidence file index

| File | Relevance |
|------|-----------|
| `src/WebhookClient/Program.cs` | Web app bootstrap; `MapWebhookEndpoints()` (line 29) |
| `src/WebhookClient/Endpoints/WebhookEndpoints.cs` | `OPTIONS /check`, `POST /webhook-received` |
| `src/WebhookClient/Endpoints/AuthenticationEndpoints.cs` | `POST /logout` |
| `src/WebhookClient/Extensions/Extensions.cs` | `WebhooksClient` HTTP client → `http://webhooks-api` (line 19) |
| `src/WebhookClient/Services/WebHooksClient.cs` | Outbound subscribe/load (`POST`/`GET /api/webhooks`) |
| `src/WebhookClient/WebhookClient.csproj` | SDK.Web project; references ServiceDefaults |
| `src/Webhooks.API/Services/GrantUrlTesterService.cs` | Sends `OPTIONS` to subscriber `/check` |
| `src/Webhooks.API/Services/WebhooksSender.cs` | `POST`s payload to DB-stored `DestUrl` |
| `src/Webhooks.API/IntegrationEvents/OrderStatusChangedToShippedIntegrationEventHandler.cs` | Event → `SendAll(...)` trigger |
| `src/eShop.AppHost/Program.cs` | Registers `webhooksclient`, wires `webHooksApi` + callback URL (lines 65-67, 94, 100) |
| `eShop.slnx` / `eShop.Web.slnf` | Solution membership (false-positive disproof) |
