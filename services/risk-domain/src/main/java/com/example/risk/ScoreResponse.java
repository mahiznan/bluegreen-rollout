package com.example.risk;

public record ScoreResponse(int score, String decision, String ruleSet, ServedBy served) {
}
