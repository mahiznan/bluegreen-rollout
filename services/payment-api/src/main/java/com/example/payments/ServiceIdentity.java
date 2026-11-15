package com.example.payments;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.HexFormat;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Component;

import com.example.payments.dto.ServedBy;

@Component
public class ServiceIdentity {

    private final ServedBy served;

    public ServiceIdentity(@Value("${spring.application.name}") String service,
                           @Value("${app.commit}") String commit,
                           @Value("${app.pod}") String pod,
                           @Value("${payments.api-key}") String apiKey) {
        this.served = new ServedBy(service, commit, pod, fingerprint(apiKey));
    }

    public ServedBy served() {
        return served;
    }

    /** First 8 hex characters of SHA-256 of the secret, or "none" when no secret is set. */
    static String fingerprint(String secret) {
        if (secret == null || secret.isBlank()) {
            return "none";
        }
        try {
            byte[] hash = MessageDigest.getInstance("SHA-256").digest(secret.getBytes(StandardCharsets.UTF_8));
            return HexFormat.of().formatHex(hash).substring(0, 8);
        } catch (NoSuchAlgorithmException e) {
            throw new IllegalStateException(e);
        }
    }
}
