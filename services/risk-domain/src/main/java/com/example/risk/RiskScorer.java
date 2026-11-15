package com.example.risk;

import java.math.BigDecimal;
import java.math.RoundingMode;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Service;

/**
 * Deliberately simple and deterministic: score = amount / 20, capped at 99.
 * 250.00 -> 12, 1200.00 -> 60, 1800.00 -> 90. The thresholds come from the ConfigMap,
 * so two releases with different config give different decisions for the same amount.
 */
@Service
public class RiskScorer {

    private static final BigDecimal DIVISOR = BigDecimal.valueOf(20);
    private static final BigDecimal MAX_SCORE = BigDecimal.valueOf(99);

    private final String ruleSet;
    private final int reviewThreshold;
    private final int declineThreshold;

    public RiskScorer(@Value("${risk.rule-set}") String ruleSet,
                      @Value("${risk.review-threshold}") int reviewThreshold,
                      @Value("${risk.decline-threshold}") int declineThreshold) {
        this.ruleSet = ruleSet;
        this.reviewThreshold = reviewThreshold;
        this.declineThreshold = declineThreshold;
    }

    public int score(BigDecimal amount) {
        return amount.divide(DIVISOR, 0, RoundingMode.DOWN).min(MAX_SCORE).intValue();
    }

    public String decision(int score) {
        if (score >= declineThreshold) {
            return "DECLINE";
        }
        if (score >= reviewThreshold) {
            return "REVIEW";
        }
        return "APPROVE";
    }

    public String ruleSet() {
        return ruleSet;
    }
}
