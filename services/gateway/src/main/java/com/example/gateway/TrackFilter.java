package com.example.gateway;

import java.nio.charset.StandardCharsets;
import java.util.Locale;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.core.Ordered;
import org.springframework.http.HttpHeaders;
import org.springframework.http.HttpStatus;
import org.springframework.http.MediaType;
import org.springframework.http.server.reactive.ServerHttpRequest;
import org.springframework.stereotype.Component;
import org.springframework.web.server.ServerWebExchange;
import org.springframework.web.server.WebFilter;
import org.springframework.web.server.WebFilterChain;

import reactor.core.publisher.Mono;

/**
 * Decides the TRACK once, at the edge, and stamps it into X-Track.
 *
 * It is a WebFilter (not a gateway filter) on purpose: it must run BEFORE route matching,
 * because the routes select their target by reading X-Track.
 *
 * There is ONE public gateway URL, so the Host header cannot tell live from pilot. What differs
 * is which MFE the page came from, and the browser reports that in the Origin header.
 *
 *   request to the public host
 *     path           Origin                  X-User-Group   track    result
 *     /api/v1/payments/**  mfe (live)        any            live     live addresses
 *     /api/v1/payments/**  mfe-preview        pilot          pilot    preview addresses
 *     /api/v1/payments/**  mfe-preview        anything else  -        403
 *     /api/v1/payments/**  missing / other    -              -        403
 *     any other path       -                  -              -        404 (domain API is internal)
 *   request to any other host (the internal eAPI -> gateway -> domain hop; never exposed by a Route)
 *                          from the incoming X-Track; missing or invalid = 403
 *
 * CORS preflights are answered earlier by CorsWebFilter and never reach this filter.
 * Any X-Track a client sends is overwritten, so a client cannot pick the preview track by header.
 */
@Component
public class TrackFilter implements WebFilter, Ordered {

    static final String TRACK = "X-Track";
    static final String GROUP = "X-User-Group";
    private static final String PAYMENTS_PATH = "/api/v1/payments";

    private final String publicHost;
    private final String liveOrigin;
    private final String previewOrigin;

    public TrackFilter(@Value("${gateway.edge.public-host}") String publicHost,
                       @Value("${gateway.edge.live-origin}") String liveOrigin,
                       @Value("${gateway.edge.preview-origin}") String previewOrigin) {
        this.publicHost = publicHost.toLowerCase(Locale.ROOT);
        this.liveOrigin = normalize(liveOrigin);
        this.previewOrigin = normalize(previewOrigin);
    }

    @Override
    public int getOrder() {
        // After CorsWebFilter (HIGHEST_PRECEDENCE), before everything else.
        return Ordered.HIGHEST_PRECEDENCE + 10;
    }

    @Override
    public Mono<Void> filter(ServerWebExchange exchange, WebFilterChain chain) {
        ServerHttpRequest request = exchange.getRequest();
        String path = request.getPath().value();

        // Probes hit the pod directly (host = pod IP) and are not gateway traffic.
        if (path.startsWith("/actuator")) {
            return chain.filter(exchange);
        }

        String track;
        if (hostOf(request).equals(publicHost)) {
            if (!path.startsWith(PAYMENTS_PATH)) {
                return reject(exchange, HttpStatus.NOT_FOUND, "not found");
            }
            String origin = normalize(request.getHeaders().getFirst(HttpHeaders.ORIGIN));
            if (origin.equals(liveOrigin)) {
                track = "live";
            } else if (origin.equals(previewOrigin)) {
                if (!"pilot".equalsIgnoreCase(request.getHeaders().getFirst(GROUP))) {
                    return reject(exchange, HttpStatus.FORBIDDEN, "preview is for the pilot group only");
                }
                track = "pilot";
            } else {
                return reject(exchange, HttpStatus.FORBIDDEN, "missing or unknown Origin");
            }
        } else {
            String incoming = request.getHeaders().getFirst(TRACK);
            if (!"live".equals(incoming) && !"pilot".equals(incoming)) {
                return reject(exchange, HttpStatus.FORBIDDEN, "missing or invalid X-Track");
            }
            track = incoming;
        }

        ServerHttpRequest stamped = request.mutate().headers(h -> h.set(TRACK, track)).build();
        // Visible to the caller, handy when testing: which track did the edge choose?
        exchange.getResponse().getHeaders().set(TRACK, track);
        return chain.filter(exchange.mutate().request(stamped).build());
    }

    private static String hostOf(ServerHttpRequest request) {
        String host = request.getHeaders().getFirst(HttpHeaders.HOST);
        if (host == null) {
            host = request.getURI().getHost();
        }
        if (host == null) {
            return "";
        }
        int colon = host.indexOf(':');
        return (colon >= 0 ? host.substring(0, colon) : host).toLowerCase(Locale.ROOT);
    }

    /** Lower-case, no trailing slash. A missing header becomes "" and matches nothing. */
    private static String normalize(String origin) {
        if (origin == null) {
            return "";
        }
        String o = origin.trim().toLowerCase(Locale.ROOT);
        return o.endsWith("/") ? o.substring(0, o.length() - 1) : o;
    }

    private static Mono<Void> reject(ServerWebExchange exchange, HttpStatus status, String message) {
        exchange.getResponse().setStatusCode(status);
        exchange.getResponse().getHeaders().setContentType(MediaType.APPLICATION_JSON);
        byte[] body = ("{\"error\":\"" + message + "\"}").getBytes(StandardCharsets.UTF_8);
        return exchange.getResponse().writeWith(
                Mono.just(exchange.getResponse().bufferFactory().wrap(body)));
    }
}
