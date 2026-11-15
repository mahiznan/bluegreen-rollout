package com.example.risk;

import java.math.BigDecimal;

import org.springframework.http.HttpStatus;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.web.server.ResponseStatusException;

@RestController
@RequestMapping("/api/risk")
public class RiskController {

    private final RiskScorer scorer;
    private final ServiceIdentity identity;

    public RiskController(RiskScorer scorer, ServiceIdentity identity) {
        this.scorer = scorer;
        this.identity = identity;
    }

    @GetMapping("/score")
    public ScoreResponse score(@RequestParam BigDecimal amount) {
        if (amount.signum() < 0) {
            throw new ResponseStatusException(HttpStatus.BAD_REQUEST, "amount must not be negative");
        }
        int score = scorer.score(amount);
        return new ScoreResponse(score, scorer.decision(score), scorer.ruleSet(), identity.served());
    }
}
