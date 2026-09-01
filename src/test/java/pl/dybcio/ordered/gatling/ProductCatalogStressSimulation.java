package pl.dybcio.ordered.gatling;

import static io.gatling.javaapi.core.CoreDsl.*;
import static io.gatling.javaapi.http.HttpDsl.*;

import io.gatling.javaapi.core.ScenarioBuilder;
import io.gatling.javaapi.core.Simulation;
import io.gatling.javaapi.http.HttpProtocolBuilder;
import java.time.Duration;

public class ProductCatalogStressSimulation extends Simulation {

  private static final String BASE_URL = System.getProperty("baseUrl", "http://localhost:8080");

  HttpProtocolBuilder httpProtocol = http.baseUrl(BASE_URL).acceptHeader("application/json");

  ScenarioBuilder browseHeavy =
      scenario("Product catalog read stress (Redis cache)")
          .exec(
              http("List products (page)")
                  .get("/api/v1/products?page=0&size=20")
                  .check(status().is(200))
                  .check(jsonPath("$.content[0].id").optional().saveAs("productId")))
          .pause(Duration.ofMillis(50))
          .doIf(session -> session.contains("productId"))
          .then(
              exec(
                  http("Get single product (cached price/stock)")
                      .get("/api/v1/products/#{productId}")
                      .check(status().is(200))));

  {
    setUp(
            browseHeavy.injectOpen(
                rampUsersPerSec(5).to(30).during(Duration.ofSeconds(20)),
                constantUsersPerSec(30).during(Duration.ofSeconds(40)),
                rampUsersPerSec(30).to(0).during(Duration.ofSeconds(10))))
        .protocols(httpProtocol)
        .assertions(
            global().successfulRequests().percent().gt(99.0),
            global().responseTime().percentile3().lt(1000));
  }
}
