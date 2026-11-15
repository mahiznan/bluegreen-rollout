package com.example.gateway;

import java.util.List;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.core.Ordered;
import org.springframework.core.annotation.Order;
import org.springframework.web.cors.CorsConfiguration;
import org.springframework.web.cors.reactive.CorsWebFilter;
import org.springframework.web.cors.reactive.UrlBasedCorsConfigurationSource;

/**
 * CORS for exactly the two MFE origins (live and preview).
 *
 * It runs BEFORE TrackFilter. A browser's preflight OPTIONS request carries no X-User-Group
 * and no Idempotency-Key, so it must be answered here and never reach the track rules.
 * An origin that is not on the list is rejected with 403 by this filter.
 */
@Configuration
public class CorsConfig {

    @Bean
    @Order(Ordered.HIGHEST_PRECEDENCE)
    public CorsWebFilter corsWebFilter(@Value("${gateway.edge.live-origin}") String liveOrigin,
                                       @Value("${gateway.edge.preview-origin}") String previewOrigin) {
        CorsConfiguration config = new CorsConfiguration();
        config.setAllowedOrigins(List.of(liveOrigin, previewOrigin));
        config.setAllowedMethods(List.of("GET", "POST", "OPTIONS"));
        config.setAllowedHeaders(List.of("Content-Type", "Idempotency-Key", "X-User-Group"));
        // Lets the page read which track answered (handy when debugging in the browser).
        config.setExposedHeaders(List.of("X-Track"));
        config.setAllowCredentials(false);
        config.setMaxAge(3600L);

        UrlBasedCorsConfigurationSource source = new UrlBasedCorsConfigurationSource();
        source.registerCorsConfiguration("/api/**", config);
        return new CorsWebFilter(source);
    }
}
