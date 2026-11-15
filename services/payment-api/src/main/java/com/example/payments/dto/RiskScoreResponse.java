package com.example.payments.dto;

/** What risk-domain returns. Unknown fields are ignored. */
public record RiskScoreResponse(int score, String decision, String ruleSet, ServedBy served) {
}
