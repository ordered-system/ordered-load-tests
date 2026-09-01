#!/usr/bin/env bash
#
# Full end-to-end smoke test for ordered-system, through the gateway. Exercises the entire
# distributed flow in one run:
#
#   register -> login -> become-seller -> create product -> browse -> view (async browsing
#   history) -> add to cart -> place order -> admin transitions order to DELIVERED -> Kafka
#   propagates order-delivered to engagement-service -> review unlocks -> review is publicly
#   visible
#
# This is meant to replace clicking through the whole thing by hand after a deploy or a big
# refactor. Requires: curl, openssl, bash 4+.
#
# Usage:
#   ./scripts/smoke-test-full-flow.sh
#   GATEWAY_URL=http://localhost:8080 JWT_SECRET=... ./scripts/smoke-test-full-flow.sh
#
set -euo pipefail

GATEWAY_URL="${GATEWAY_URL:-http://localhost:8080}"
JWT_SECRET="${JWT_SECRET:-change-me-in-prod-min-256-bits-long-please-replace}"
HEALTH_TIMEOUT_SECONDS="${HEALTH_TIMEOUT_SECONDS:-30}"
KAFKA_PROPAGATION_TIMEOUT_SECONDS="${KAFKA_PROPAGATION_TIMEOUT_SECONDS:-15}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

pass_count=0
fail_count=0

log()  { echo -e "$1"; }
step() { log "\n${YELLOW}==>${NC} $1"; }
ok()   { log "${GREEN}  OK${NC} - $1"; pass_count=$((pass_count + 1)); }
fail() { log "${RED}  FAIL${NC} - $1"; fail_count=$((fail_count + 1)); }
die()  { log "${RED}FATAL:${NC} $1"; exit 1; }

# ---------------------------------------------------------------------------
# JWT helper - only needed for the ADMIN token. There's no self-service path
# to ROLE_ADMIN (by design - see ordered-user-service), so this hand-signs one
# the same way the project's other smoke tests and cross-service tests already
# do for synthetic roles.
# ---------------------------------------------------------------------------

base64url() { base64 | tr '+/' '-_' | tr -d '=\n'; }

make_jwt() {
  local user_id="$1" email="$2" roles_json="$3"
  local now exp header payload header_b64 payload_b64 signing_input signature
  now=$(date +%s)
  exp=$((now + 3600))
  header='{"alg":"HS256","typ":"JWT"}'
  payload=$(printf '{"sub":"%s","userId":%s,"roles":%s,"iat":%s,"exp":%s}' \
    "$email" "$user_id" "$roles_json" "$now" "$exp")
  header_b64=$(printf '%s' "$header" | base64url)
  payload_b64=$(printf '%s' "$payload" | base64url)
  signing_input="${header_b64}.${payload_b64}"
  signature=$(printf '%s' "$signing_input" | openssl dgst -sha256 -hmac "$JWT_SECRET" -binary | base64url)
  printf '%s.%s' "$signing_input" "$signature"
}

extract_json_string() {
  echo "$2" | grep -oE "\"$1\":\"[^\"]*\"" | head -1 | cut -d'"' -f4
}

extract_json_number() {
  echo "$2" | grep -oE "\"$1\":[0-9]+" | head -1 | grep -oE '[0-9]+$'
}

wait_for_health() {
  local name="$1" url="$2"
  local deadline=$((SECONDS + HEALTH_TIMEOUT_SECONDS))
  while [ $SECONDS -lt $deadline ]; do
    if curl -sf "$url" >/dev/null 2>&1; then
      ok "$name is up"
      return 0
    fi
    sleep 1
  done
  fail "$name did not become healthy within ${HEALTH_TIMEOUT_SECONDS}s"
  return 1
}

# ---------------------------------------------------------------------------
# 1. Health checks (through the gateway where possible)
# ---------------------------------------------------------------------------

step "Checking gateway is reachable"
wait_for_health "gateway" "$GATEWAY_URL/actuator/health" || die "gateway not reachable"

step "Quick check that per-service docs routes resolve (informational only - not required for the rest of this script)"
for pair in "order-service:$GATEWAY_URL/order-service/v3/api-docs" \
            "product-service:$GATEWAY_URL/product-service/v3/api-docs" \
            "user-service:$GATEWAY_URL/user-service/v3/api-docs" \
            "engagement-service:$GATEWAY_URL/engagement-service/v3/api-docs"; do
  name="${pair%%:*}"
  url="${pair#*:}"
  status=$(curl -s -o /dev/null -w "%{http_code}" "$url" || echo "000")
  if [ "$status" = "200" ]; then
    ok "$name docs route resolves"
  else
    log "  ${YELLOW}skip${NC} - $name docs route returned $status (fine if Swagger isn't deployed yet)"
  fi
done

# ---------------------------------------------------------------------------
# 2. Register buyer + seller, log in
# ---------------------------------------------------------------------------

RUN_ID=$(date +%s)
BUYER_EMAIL="smoke-buyer-$RUN_ID@test.pl"
SELLER_EMAIL="smoke-seller-$RUN_ID@test.pl"
PASSWORD="haslo1234"

step "Registering buyer and seller"
curl -sf -X POST "$GATEWAY_URL/api/v1/auth/register" -H "Content-Type: application/json" \
  -d "{\"email\":\"$BUYER_EMAIL\",\"password\":\"$PASSWORD\",\"firstName\":\"Smoke\",\"lastName\":\"Buyer\"}" \
  >/dev/null && ok "buyer registered" || fail "buyer registration failed"

curl -sf -X POST "$GATEWAY_URL/api/v1/auth/register" -H "Content-Type: application/json" \
  -d "{\"email\":\"$SELLER_EMAIL\",\"password\":\"$PASSWORD\",\"firstName\":\"Smoke\",\"lastName\":\"Seller\"}" \
  >/dev/null && ok "seller registered" || fail "seller registration failed"

step "Logging in"
BUYER_LOGIN=$(curl -sf -X POST "$GATEWAY_URL/api/v1/auth/login" -H "Content-Type: application/json" \
  -d "{\"email\":\"$BUYER_EMAIL\",\"password\":\"$PASSWORD\"}") || die "buyer login failed"
BUYER_TOKEN=$(extract_json_string token "$BUYER_LOGIN")
[ -n "$BUYER_TOKEN" ] && ok "buyer logged in" || fail "could not parse buyer token"

SELLER_LOGIN=$(curl -sf -X POST "$GATEWAY_URL/api/v1/auth/login" -H "Content-Type: application/json" \
  -d "{\"email\":\"$SELLER_EMAIL\",\"password\":\"$PASSWORD\"}") || die "seller login failed"
SELLER_USER_TOKEN=$(extract_json_string token "$SELLER_LOGIN")
[ -n "$SELLER_USER_TOKEN" ] && ok "seller logged in" || fail "could not parse seller token"

step "Promoting seller to SELLER role"
SELLER_PROMOTION=$(curl -sf -X POST "$GATEWAY_URL/api/v1/users/me/become-seller" \
  -H "Authorization: Bearer $SELLER_USER_TOKEN") || die "become-seller failed"
SELLER_TOKEN=$(extract_json_string token "$SELLER_PROMOTION")
[ -n "$SELLER_TOKEN" ] && ok "seller promoted, fresh SELLER token obtained" || fail "could not parse promoted token"

# ---------------------------------------------------------------------------
# 3. Create a product, browse, view (exercises async browsing-history)
# ---------------------------------------------------------------------------

step "Creating a product as seller"
CREATE_RESPONSE=$(curl -sf -X POST "$GATEWAY_URL/api/v1/products" \
  -H "Authorization: Bearer $SELLER_TOKEN" -H "Content-Type: application/json" \
  -d '{"name":"Smoke Test Mechanical Keyboard","description":"full-flow smoke test","price":249.99,"stockQuantity":10}') \
  || die "product creation failed"
PRODUCT_ID=$(extract_json_number id "$CREATE_RESPONSE")
[ -n "$PRODUCT_ID" ] && ok "created product id=$PRODUCT_ID" || die "could not parse product id: $CREATE_RESPONSE"

step "Browsing the catalog"
LIST_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "$GATEWAY_URL/api/v1/products?page=0&size=20")
[ "$LIST_STATUS" = "200" ] && ok "GET /api/v1/products returned 200" || fail "GET /api/v1/products returned $LIST_STATUS"

step "Viewing the product as buyer (fires async browsing-history call)"
VIEW_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "$GATEWAY_URL/api/v1/products/$PRODUCT_ID" \
  -H "Authorization: Bearer $BUYER_TOKEN")
[ "$VIEW_STATUS" = "200" ] && ok "GET /api/v1/products/$PRODUCT_ID returned 200" || fail "GET /api/v1/products/$PRODUCT_ID returned $VIEW_STATUS"

# ---------------------------------------------------------------------------
# 4. Cart + place order
# ---------------------------------------------------------------------------

step "Adding product to buyer's cart"
CART_STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$GATEWAY_URL/api/v1/cart/items" \
  -H "Authorization: Bearer $BUYER_TOKEN" -H "Content-Type: application/json" \
  -d "{\"productId\":$PRODUCT_ID,\"quantity\":1}")
[ "$CART_STATUS" = "200" ] && ok "added to cart" || die "add-to-cart returned $CART_STATUS"

step "Placing order"
ORDER_RESPONSE=$(curl -sf -X POST "$GATEWAY_URL/api/v1/orders" \
  -H "Authorization: Bearer $BUYER_TOKEN" -H "Content-Type: application/json" \
  -d '{
        "deliveryAddress": {
          "recipientName": "Smoke Test",
          "phone": "+48123456789",
          "street": "Testowa",
          "buildingNumber": "1",
          "city": "Torun",
          "postalCode": "87-100",
          "country": "PL"
        }
      }') || die "order placement failed"
ORDER_ID=$(extract_json_number id "$ORDER_RESPONSE")
[ -n "$ORDER_ID" ] && ok "order placed, id=$ORDER_ID" || die "could not parse order id: $ORDER_RESPONSE"

# ---------------------------------------------------------------------------
# 5. Admin drives the order to DELIVERED. There's no self-service path to
#    ROLE_ADMIN, so this uses a hand-signed token - same as elsewhere in the
#    project's test suite. The order might be CONFIRMED or PAYMENT_PENDING at
#    this point depending on whether a real Stripe test key is configured;
#    both allow the same CONFIRMED -> SHIPPED -> DELIVERED path from here.
# ---------------------------------------------------------------------------

ADMIN_TOKEN=$(make_jwt 999999 "smoke-admin@example.com" '["ROLE_ADMIN"]')

advance_order_status() {
  local target_status="$1"
  local status
  status=$(curl -s -o /dev/null -w "%{http_code}" -X PATCH "$GATEWAY_URL/api/v1/orders/$ORDER_ID/status" \
    -H "Authorization: Bearer $ADMIN_TOKEN" -H "Content-Type: application/json" \
    -d "{\"status\":\"$target_status\"}")
  if [ "$status" = "200" ]; then
    ok "order -> $target_status"
  else
    fail "PATCH order status to $target_status returned $status"
  fi
}

step "Admin driving order to DELIVERED"
CURRENT_ORDER=$(curl -sf "$GATEWAY_URL/api/v1/orders/$ORDER_ID" -H "Authorization: Bearer $ADMIN_TOKEN") \
  || die "could not fetch order as admin"
CURRENT_STATUS=$(extract_json_string status "$CURRENT_ORDER")
log "  current status: ${CURRENT_STATUS:-unknown}"

if [ "$CURRENT_STATUS" = "PAYMENT_PENDING" ] || [ "$CURRENT_STATUS" = "PENDING" ]; then
  advance_order_status "CONFIRMED"
fi
advance_order_status "SHIPPED"
advance_order_status "DELIVERED"

# ---------------------------------------------------------------------------
# 6. Wait for the order-delivered Kafka event to propagate to
#    engagement-service, then confirm the review unlocks.
# ---------------------------------------------------------------------------

step "Waiting for order-delivered event to propagate via Kafka (up to ${KAFKA_PROPAGATION_TIMEOUT_SECONDS}s)"
deadline=$((SECONDS + KAFKA_PROPAGATION_TIMEOUT_SECONDS))
review_created=0
REVIEW_RESPONSE=""

while [ $SECONDS -lt $deadline ]; do
  REVIEW_STATUS=$(curl -s -o /tmp/smoke_review_body.$$ -w "%{http_code}" -X POST "$GATEWAY_URL/api/v1/reviews" \
    -H "Authorization: Bearer $BUYER_TOKEN" -H "Content-Type: application/json" \
    -d "{\"productId\":$PRODUCT_ID,\"rating\":5,\"comment\":\"Smoke test review\"}")
  REVIEW_RESPONSE=$(cat /tmp/smoke_review_body.$$ 2>/dev/null || true)
  rm -f /tmp/smoke_review_body.$$

  if [ "$REVIEW_STATUS" = "201" ]; then
    review_created=1
    break
  fi
  sleep 1
done

if [ "$review_created" = "1" ]; then
  ok "review accepted once verified purchase propagated (Kafka -> engagement-service worked)"
else
  fail "review never got accepted (last response: $REVIEW_RESPONSE) - check order-delivered consumer lag"
fi

step "Confirming the review is publicly visible"
PUBLIC_REVIEWS=$(curl -sf "$GATEWAY_URL/api/v1/reviews/product/$PRODUCT_ID") || PUBLIC_REVIEWS=""
if echo "$PUBLIC_REVIEWS" | grep -q "Smoke test review"; then
  ok "review visible via public GET /api/v1/reviews/product/$PRODUCT_ID"
else
  fail "review not found in public listing (response: $PUBLIC_REVIEWS)"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

echo
echo "-----------------------------------------"
if [ "$fail_count" -eq 0 ]; then
  echo -e "${GREEN}All $pass_count checks passed. Full flow works end to end.${NC}"
  exit 0
else
  echo -e "${RED}$fail_count check(s) failed, $pass_count passed.${NC}"
  exit 1
fi
