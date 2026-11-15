package com.example.risk;

import com.fasterxml.jackson.annotation.JsonInclude;

/**
 * "Who answered?" Included in every response so a load test can count requests per
 * release. secretFingerprint proves which secret this release runs without revealing it.
 */
@JsonInclude(JsonInclude.Include.NON_NULL)
public record ServedBy(String service, String commit, String pod, String secretFingerprint) {
}
