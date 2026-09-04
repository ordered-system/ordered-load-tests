# ordered-load-tests

Gatling load-testing simulations for [ordered-system](https://github.com/ordered-system), run against [`ordered-gateway`](https://github.com/ordered-system/ordered-gateway) rather than any single service — the point is to exercise the whole distributed system the way real traffic would, and compare the numbers against the old [`ordered-backend`](https://github.com/ordered-system/ordered-backend) monolith under the exact same injection profile.

## Simulations

| Simulation | What it exercises |
|---|---|
| `UserJourneySimulation` | The realistic end-to-end path: register → login → browse products → add to cart → place an order → payment. Mixed read/write load. |
| `ProductCatalogStressSimulation` | Read-heavy catalog browsing at high concurrency — the one that surfaces caching and connection-pool bottlenecks, since it's what motivated adding Redis cache-aside to `product-service` in the first place. |

## Scripts

Beyond the Gatling simulations themselves, two bash scripts drive the system through the gateway with real HTTP calls (no mocking):

- **`scripts/seed-products.sh`** — registers a seller, logs in, and creates a batch of products so the catalog has something to page through before a load test runs. `PRODUCT_COUNT` and `GATEWAY_URL` are configurable via env vars.
- **`scripts/smoke-test-full-flow.sh`** — a correctness check, not a load test: walks the *entire* business flow once — register → login → become seller → create product → browse → view (triggers async browsing history) → add to cart → place order → admin marks it delivered → Kafka propagates `order-delivered` to `engagement-service` → review unlocks → review is publicly visible. Useful after a deploy or a big refactor, to confirm the whole chain still works without clicking through it by hand.

## Running it

Needs the full stack up first — see [`ordered-infra`](https://github.com/ordered-system/ordered-infra) for the one-command way to start everything (gateway, all four services, Kafka, Postgres × 3, Mongo, Redis).

```bash
git clone https://github.com/ordered-system/ordered-load-tests.git
cd ordered-load-tests

make seed-load-test-data              # populate the catalog
make load-test                        # full user-journey simulation
make load-test-cache-stress           # read-heavy catalog stress simulation
make smoke-test                       # correctness check, not a load test
```

Gatling writes an HTML report under `target/gatling/` after each run — open the `index.html` it prints the path to.

Override the target if the gateway isn't on localhost:

```bash
GATEWAY_URL=http://your-host:8080 make load-test
```

## Results (reference)

Run against the fully decomposed system with Redis caching enabled on `product-service`: **100% request success rate**, ~779 ms p95 latency on the user-journey simulation and ~207 ms p95 on the catalog-stress simulation. Before the cache was added, the catalog-stress simulation saw error rates as high as 46% under the same load.

## Stack

Java 21 · Gatling 3.13 (via `gatling-maven-plugin`)

## Where this fits

Part of the [ordered-system](https://github.com/ordered-system) organization — validates [`ordered-gateway`](https://github.com/ordered-system/ordered-gateway) and the four business services under load, with results comparable against the equivalent simulations that were run on [`ordered-backend`](https://github.com/ordered-system/ordered-backend) before decomposition.

## License

MIT — see [LICENSE](LICENSE).
