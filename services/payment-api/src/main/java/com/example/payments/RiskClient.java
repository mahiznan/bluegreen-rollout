package com.example.payments;

import java.math.BigDecimal;
import java.net.http.HttpClient;
import java.time.Duration;
import java.util.Set;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.client.JdkClientHttpRequestFactory;
import org.springframework.stereotype.Component;
import org.springframework.web.client.RestClient;
import org.springframework.web.client.RestClientException;

import com.example.payments.dto.RiskScoreResponse;

/**
 * Calls the domain API. The track (live or pilot) was decided once at the edge and arrives
 * here as the X-Track header. This client only FORWARDS it; it never decides anything.
 */
@Component
public class RiskClient {

    /** Only these values are forwarded, so a garbage header cannot be echoed downstream. */
    private static final Set<String> TRACKS = Set.of("live", "pilot");

    private final RestClient client;

    public RiskClient(@Value("${downstream.risk-domain.url}") String baseUrl,
                      @Value("${downstream.risk-domain.connect-timeout-ms}") long connectTimeoutMs,
                      @Value("${downstream.risk-domain.read-timeout-ms}") long readTimeoutMs) {
        HttpClient http = HttpClient.newBuilder()
                .version(HttpClient.Version.HTTP_1_1)
                .connectTimeout(Duration.ofMillis(connectTimeoutMs))
                .build();
        JdkClientHttpRequestFactory factory = new JdkClientHttpRequestFactory(http);
        factory.setReadTimeout(Duration.ofMillis(readTimeoutMs));
        this.client = RestClient.builder().baseUrl(baseUrl).requestFactory(factory).build();
    }

    public RiskScoreResponse score(BigDecimal amount, String track) {
        try {
            RiskScoreResponse body = client.get()
                    .uri(b -> b.path("/api/risk/score").queryParam("amount", amount.toPlainString()).build())
                    .headers(h -> {
                        if (track != null && TRACKS.contains(track)) {
                            h.set("X-Track", track);
                        }
                    })
                    .retrieve()
                    .body(RiskScoreResponse.class);
            if (body == null) {
                throw new RiskUnavailableException("risk-domain returned an empty body", null);
            }
            return body;
        } catch (RestClientException e) {
            throw new RiskUnavailableException("risk-domain call failed: " + e.getMessage(), e);
        }
    }
}
