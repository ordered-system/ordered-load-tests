#!/usr/bin/env bash
#
# Seeds sample products for the Gatling load tests, via real API calls through the gateway
# (register -> login -> become-seller -> create product x N). Idempotent-ish: reruns just create
# another seller and another batch of products, which is fine for load-test data - it doesn't
# need to be unique, it just needs enough rows for the catalog listing to have something to page
# through.
#
# Usage:
#   ./scripts/seed-products.sh
#   PRODUCT_COUNT=100 GATEWAY_URL=http://localhost:8080 ./scripts/seed-products.sh
#
set -euo pipefail

GATEWAY_URL="${GATEWAY_URL:-http://localhost:8080}"
PRODUCT_COUNT="${PRODUCT_COUNT:-50}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "$1"; }
step() { log "\n${YELLOW}==>${NC} $1"; }
die()  { log "${RED}FATAL:${NC} $1"; exit 1; }

SELLER_EMAIL="seed-seller-$(date +%s)@test.pl"
SELLER_PASSWORD="haslo1234"

step "Registering seed seller ($SELLER_EMAIL)"
curl -sf -X POST "$GATEWAY_URL/api/v1/auth/register" \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"$SELLER_EMAIL\",\"password\":\"$SELLER_PASSWORD\",\"firstName\":\"Seed\",\"lastName\":\"Seller\"}" \
  >/dev/null || die "registration failed - is user-service up (via gateway)?"

step "Logging in"
LOGIN_RESPONSE=$(curl -sf -X POST "$GATEWAY_URL/api/v1/auth/login" \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"$SELLER_EMAIL\",\"password\":\"$SELLER_PASSWORD\"}") \
  || die "login failed"
USER_TOKEN=$(echo "$LOGIN_RESPONSE" | grep -oE '"token":"[^"]+"' | cut -d'"' -f4)
[ -n "$USER_TOKEN" ] || die "could not parse token from login response: $LOGIN_RESPONSE"

step "Promoting to SELLER"
SELLER_RESPONSE=$(curl -sf -X POST "$GATEWAY_URL/api/v1/users/me/become-seller" \
  -H "Authorization: Bearer $USER_TOKEN") \
  || die "become-seller failed"
SELLER_TOKEN=$(echo "$SELLER_RESPONSE" | grep -oE '"token":"[^"]+"' | cut -d'"' -f4)
[ -n "$SELLER_TOKEN" ] || die "could not parse token from become-seller response: $SELLER_RESPONSE"

step "Creating $PRODUCT_COUNT products"
ADJECTIVES=("Mechanical" "Wireless" "Ergonomic" "Compact" "Portable" "Premium" "Budget" "Retro")
NOUNS=("Keyboard" "Mouse" "Monitor" "Headset" "Webcam" "Speaker" "Charger" "Cable")

created=0
for i in $(seq 1 "$PRODUCT_COUNT"); do
  adj=${ADJECTIVES[$((RANDOM % ${#ADJECTIVES[@]}))]}
  noun=${NOUNS[$((RANDOM % ${#NOUNS[@]}))]}
  price=$(( (RANDOM % 20000 + 999) ))
  price_formatted="${price:0:-2}.${price: -2}"
  stock=$((RANDOM % 100 + 1))

  status=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$GATEWAY_URL/api/v1/products" \
    -H "Authorization: Bearer $SELLER_TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"name\":\"$adj $noun #$i\",\"description\":\"Seeded for load testing\",\"price\":$price_formatted,\"stockQuantity\":$stock}")

  if [ "$status" = "201" ]; then
    created=$((created + 1))
  else
    log "${RED}  product $i failed (HTTP $status)${NC}"
  fi
done

log "\n${GREEN}Created $created/$PRODUCT_COUNT products.${NC}"
[ "$created" -gt 0 ] || die "no products were created - check product-service logs"
