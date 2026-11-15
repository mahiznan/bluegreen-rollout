package com.example.payments;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.HexFormat;
import java.util.Map;
import java.util.Optional;
import java.util.concurrent.ConcurrentHashMap;

import org.springframework.stereotype.Service;

import com.example.payments.dto.AuthorizeRequest;
import com.example.payments.dto.AuthorizeResponse;
import com.example.payments.dto.RiskScoreResponse;
import com.example.payments.dto.RiskSummary;
import com.example.payments.dto.Served;

@Service
public class PaymentService {

    private final BankGateway bank;
    private final RiskClient risk;
    private final ServiceIdentity identity;

    /**
     * Idempotency store, keyed by authId, in this pod's memory only (a real service would
     * use Redis or a database). A replay is answered from here and does not call the domain.
     */
    private final Map<String, AuthorizeResponse> store = new ConcurrentHashMap<>();

    public PaymentService(BankGateway bank, RiskClient risk, ServiceIdentity identity) {
        this.bank = bank;
        this.risk = risk;
        this.identity = identity;
    }

    public AuthorizeResponse authorize(String idempotencyKey, AuthorizeRequest request, String track) {
        String authId = authIdFor(idempotencyKey);

        AuthorizeResponse existing = store.get(authId);
        if (existing != null) {
            return existing.asReplay(identity.served());
        }

        // Domain hop: score first. A declined payment never reaches the bank.
        RiskScoreResponse score = risk.score(request.amount(), track);

        String status;
        if ("DECLINE".equals(score.decision())) {
            status = "DECLINED";
        } else {
            bank.approve(); // slow downstream call, may throw BankUnavailableException
            status = "REVIEW".equals(score.decision()) ? "PENDING_REVIEW" : "APPROVED";
        }

        AuthorizeResponse created = new AuthorizeResponse(
                authId, status, request.orderId(), false,
                new RiskSummary(score.score(), score.decision(), score.ruleSet()),
                new Served(identity.served(), score.served()));
        AuthorizeResponse raced = store.putIfAbsent(authId, created);
        return raced != null ? raced.asReplay(identity.served()) : created;
    }

    public Optional<AuthorizeResponse> find(String authId) {
        return Optional.ofNullable(store.get(authId));
    }

    /** "auth_" + first 20 hex chars of SHA-256(key). The same key always gives the same id. */
    static String authIdFor(String idempotencyKey) {
        try {
            byte[] hash = MessageDigest.getInstance("SHA-256")
                    .digest(idempotencyKey.getBytes(StandardCharsets.UTF_8));
            return "auth_" + HexFormat.of().formatHex(hash).substring(0, 20);
        } catch (NoSuchAlgorithmException e) {
            throw new IllegalStateException("SHA-256 not available", e);
        }
    }
}
