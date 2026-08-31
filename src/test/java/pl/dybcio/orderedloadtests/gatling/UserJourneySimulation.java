package pl.dybcio.orderedloadtests.gatling;

import static io.gatling.javaapi.core.CoreDsl.*;
import static io.gatling.javaapi.http.HttpDsl.*;

import io.gatling.javaapi.core.ChainBuilder;
import io.gatling.javaapi.core.ScenarioBuilder;
import io.gatling.javaapi.core.Simulation;
import io.gatling.javaapi.http.HttpProtocolBuilder;
import java.time.Duration;
import java.util.Iterator;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.stream.Stream;

public class UserJourneySimulation extends Simulation {

  private static final String BASE_URL = System.getProperty("baseUrl", "http://localhost:8080");

  HttpProtocolBuilder httpProtocol =
      http.baseUrl(BASE_URL).acceptHeader("application/json").contentTypeHeader("application/json");

  Iterator<Map<String, Object>> userFeeder =
      Stream.generate(
              (java.util.function.Supplier<Map<String, Object>>)
                  () ->
                      Map.of(
                          "email",
                          "loadtest-" + UUID.randomUUID() + "@test.pl",
                          "password",
                          "haslo1234"))
          .iterator();

  ChainBuilder registerAndLogin =
      exec(http("Register")
              .post("/api/v1/auth/register")
              .body(
                  StringBody(
                      "{\"email\":\"#{email}\",\"password\":\"#{password}\",\"firstName\":\"Load\",\"lastName\":\"Test\"}"))
              .check(status().is(201)))
          .exec(
              http("Login")
                  .post("/api/v1/auth/login")
                  .body(StringBody("{\"email\":\"#{email}\",\"password\":\"#{password}\"}"))
                  .check(status().is(200))
                  .check(jsonPath("$.token").saveAs("authToken")));

  ChainBuilder browseProducts =
      exec(
          http("List products")
              .get("/api/v1/products?page=0&size=20")
              .check(status().is(200))
              .check(jsonPath("$.content[*].id").findAll().optional().saveAs("productIds")));

  ChainBuilder viewRandomProduct =
      exec(session -> {
            List<Object> ids =
                session.contains("productIds") ? session.getList("productIds") : List.of();
            if (ids.isEmpty()) {
              return session;
            }
            Object randomId = ids.get(new java.util.Random().nextInt(ids.size()));
            return session.set("viewProductId", randomId);
          })
          .doIf(session -> session.contains("viewProductId"))
          .then(
              exec(
                  http("View product detail")
                      .get("/api/v1/products/#{viewProductId}")
                      .header("Authorization", "Bearer #{authToken}")
                      .check(status().is(200))));

  ChainBuilder addToCartAndPlaceOrder =
      exec(session -> {
            List<Object> ids =
                session.contains("productIds") ? session.getList("productIds") : List.of();
            return ids.isEmpty() ? session : session.set("orderProductId", ids.get(0));
          })
          .doIf(session -> session.contains("orderProductId"))
          .then(
              exec(http("Add to cart")
                      .post("/api/v1/cart/items")
                      .header("Authorization", "Bearer #{authToken}")
                      .body(StringBody("{\"productId\":#{orderProductId},\"quantity\":1}"))
                      .check(status().is(200)))
                  .exec(
                      http("Place order")
                          .post("/api/v1/orders")
                          .header("Authorization", "Bearer #{authToken}")
                          .body(
                              StringBody(
                                  """
                                  {
                                    "deliveryAddress": {
                                      "recipientName": "Load Test",
                                      "phone": "+48123456789",
                                      "street": "Testowa",
                                      "buildingNumber": "1",
                                      "city": "Torun",
                                      "postalCode": "87-100",
                                      "country": "Poland"
                                    }
                                  }
                                  """))
                          .check(status().in(201, 400, 409))));

  ScenarioBuilder userJourney =
      scenario("Full user journey - browse and order")
          .feed(userFeeder)
          .exec(registerAndLogin)
          .pause(Duration.ofMillis(300), Duration.ofSeconds(1))
          .exec(browseProducts)
          .pause(Duration.ofMillis(200), Duration.ofSeconds(1))
          .repeat(3)
          .on(viewRandomProduct)
          .pause(Duration.ofMillis(200), Duration.ofSeconds(1))
          .exec(addToCartAndPlaceOrder);

  {
    setUp(
            userJourney.injectOpen(
                rampUsers(20).during(Duration.ofSeconds(15)),
                constantUsersPerSec(5).during(Duration.ofSeconds(60)),
                rampUsersPerSec(5).to(0).during(Duration.ofSeconds(15))))
        .protocols(httpProtocol)
        .assertions(
            global().responseTime().percentile3().lt(1500),
            global().successfulRequests().percent().gt(95.0));
  }
}
